-- schema/dump/postgresql.sql: the schema-only pg_dump of the database cortex and engine_postgresql make, as the locked design gives it.
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
-- Name: engine_postgresql; Type: SCHEMA; Schema: -; Owner: sf_owner
--

CREATE SCHEMA engine_postgresql;


ALTER SCHEMA engine_postgresql OWNER TO sf_owner;

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
DECLARE
  t text;
BEGIN
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', owner);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO sf_service, sf_agent, sf_reader', owner);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sf_service, sf_agent', owner);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sf_reader', owner);
  EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sf_service, sf_agent', owner);
  -- and the same for every table and function a later version makes (they are made as sf_owner)
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sf_service, sf_agent', owner);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT ON TABLES TO sf_reader', owner);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO sf_service, sf_agent', owner);
  IF owner = 'cortex' THEN
    -- what the agent reads only: the engine's declaration, the schema's identity, what was applied, read and locked
    FOREACH t IN ARRAY ARRAY['schema_identity', 'engine_versions', 'engine_features', 'catalog_sources', 'object_kinds',
                             'schema_migrations', 'source_reads', 'locked_versions'] LOOP
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON cortex.%I FROM sf_agent', t);
    END LOOP;
    -- the log: the agent adds to it with its work and never rewrites it
    FOREACH t IN ARRAY ARRAY['turns', 'operations', 'row_changes'] LOOP
      EXECUTE format('REVOKE UPDATE, DELETE ON cortex.%I FROM sf_agent', t);
    END LOOP;
  END IF;
END $$;


ALTER FUNCTION cortex.grant_roles(owner text) OWNER TO sf_owner;

--
-- Name: FUNCTION grant_roles(owner text); Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON FUNCTION cortex.grant_roles(owner text) IS 'gives an owner''s namespace to sf_service (rows, the rules), sf_agent (the design''s rows) and sf_reader (reading), so the schema changes only as sf_owner';


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
-- Name: branches; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.branches (
    id bigint NOT NULL,
    name text NOT NULL,
    head uuid,
    current boolean DEFAULT false NOT NULL,
    CONSTRAINT branches_name_check CHECK ((length(name) >= 1))
);


ALTER TABLE cortex.branches OWNER TO sf_owner;

--
-- Name: TABLE branches; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.branches IS 'a line of work: its newest turn. Switching branch moves the design to its newest turn.';


--
-- Name: COLUMN branches.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.branches.id IS 'issued by the database';


--
-- Name: COLUMN branches.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.branches.name IS 'main, experiment';


--
-- Name: COLUMN branches.head; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.branches.head IS 'its newest turn, or the turn it forks from before it has one (a rule holds it to a turn: turns name their branch, so a key here would be a cycle); NULL before the first turn';


--
-- Name: COLUMN branches.current; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.branches.current IS 'true for the branch the design is on: exactly one, held at commit';


--
-- Name: branches_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.branches ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.branches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: turns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.turns (
    id uuid DEFAULT uuidv7() NOT NULL,
    parent uuid,
    branch bigint NOT NULL,
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
    CONSTRAINT turns_check3 CHECK (((parent IS NULL) OR (parent <> id))),
    CONSTRAINT turns_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT turns_state_check CHECK ((state = ANY (ARRAY['open'::text, 'accepted'::text, 'rejected'::text, 'undone'::text]))),
    CONSTRAINT turns_summary_check CHECK ((length(summary) >= 1)),
    CONSTRAINT turns_who_check CHECK ((length(who) >= 1))
);


ALTER TABLE cortex.turns OWNER TO sf_owner;

--
-- Name: TABLE turns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.turns IS 'one round of work: the agent''s answer to one prompt, a person''s edit, an import, an undo, a restore. Every change belongs to one; each follows the turn before it, so turns form a tree.';


--
-- Name: COLUMN turns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.id IS 'UUIDv7, issued by the database: its order is the order turns began';


--
-- Name: COLUMN turns.parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.parent IS 'the turn it follows; NULL for the first';


--
-- Name: COLUMN turns.branch; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.branch IS 'the branch it was made on';


--
-- Name: COLUMN turns.by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.by IS 'who made it';


--
-- Name: COLUMN turns.who; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.who IS 'the agent''s label, the person''s name, or the source read';


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

COMMENT ON COLUMN cortex.turns.undoes IS 'the turn this one takes back by applying its inverses; NULL for any other turn';


--
-- Name: COLUMN turns.started_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.started_at IS 'when its first change landed';


--
-- Name: COLUMN turns.ended_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.ended_at IS 'when its maker ended it; NULL while it is being made';


--
-- Name: COLUMN turns.decided_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.decided_at IS 'when it was accepted, rejected or undone; NULL while open';


--
-- Name: COLUMN turns.decided_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.turns.decided_by IS 'who decided it; NULL while open';


--
-- Name: broken_branch_heads_are_turns; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_branch_heads_are_turns AS
 SELECT 'branch-heads-are-turns'::text AS rule,
    (id)::text AS id
   FROM cortex.branches b
  WHERE ((head IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM cortex.turns t
          WHERE (t.id = b.head)))));


ALTER VIEW cortex.broken_branch_heads_are_turns OWNER TO sf_owner;

--
-- Name: VIEW broken_branch_heads_are_turns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_branch_heads_are_turns IS 'A branch''s newest turn is a turn: its own newest, or the turn it forks from before it has one.';


--
-- Name: columns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.columns (
    id bigint NOT NULL,
    object bigint NOT NULL,
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
    CONSTRAINT columns_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT columns_position_check CHECK (("position" >= 1)),
    CONSTRAINT columns_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.columns OWNER TO sf_owner;

--
-- Name: TABLE columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.columns IS 'the columns of a table, a view or a composite type, in order, with what every engine says of a column.';


--
-- Name: COLUMN columns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.id IS 'issued by the database, kept when the name changes';


--
-- Name: COLUMN columns.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.object IS 'the object it belongs to';


--
-- Name: COLUMN columns."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns."position" IS 'its place in the object: 1, 2, 3';


--
-- Name: COLUMN columns.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.name IS 'total';


--
-- Name: COLUMN columns.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.type IS 'its type as the engine writes it at the schema''s version (decimal(12,2), int(11) on MySQL 5.7)';


--
-- Name: COLUMN columns.nullable; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.nullable IS 'true when it may hold null';


--
-- Name: COLUMN columns.default_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.default_value IS 'its default, as the engine''s SQL writes it: a literal quoted, an expression as written; NULL for none';


--
-- Name: COLUMN columns.generated_expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.generated_expression IS 'the expression it is computed from, in the engine''s SQL; NULL when it is not computed';


--
-- Name: COLUMN columns.generated_stored; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.generated_stored IS 'for a computed column: true when stored, false when computed when read';


--
-- Name: COLUMN columns."collation"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns."collation" IS 'its collation where it is not its table''s, as the engine names it; NULL for the table''s';


--
-- Name: COLUMN columns.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.columns.comment IS 'what it holds: written into its SQL';


--
-- Name: constraint_columns; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.constraint_columns (
    id bigint NOT NULL,
    "constraint" bigint NOT NULL,
    "position" integer NOT NULL,
    "column" bigint NOT NULL,
    to_column bigint,
    to_column_name text,
    CONSTRAINT constraint_columns_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.constraint_columns OWNER TO sf_owner;

--
-- Name: TABLE constraint_columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.constraint_columns IS 'the columns of a key or a link, in order; for a link, each with the column it refers to.';


--
-- Name: COLUMN constraint_columns.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns.id IS 'issued by the database';


--
-- Name: COLUMN constraint_columns."constraint"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns."constraint" IS 'the key or link';


--
-- Name: COLUMN constraint_columns."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns."position" IS 'its place, 1 first';


--
-- Name: COLUMN constraint_columns."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns."column" IS 'a column of the constraint''s table';


--
-- Name: COLUMN constraint_columns.to_column; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns.to_column IS 'the column a link refers to; NULL for a key, and for a table outside the store';


--
-- Name: COLUMN constraint_columns.to_column_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraint_columns.to_column_name IS 'the referred column outside the store, as written; NULL otherwise';


--
-- Name: constraints; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.constraints (
    id bigint NOT NULL,
    object bigint NOT NULL,
    name text,
    kind text NOT NULL,
    in_database boolean DEFAULT true NOT NULL,
    enforced boolean DEFAULT true NOT NULL,
    "deferrable" boolean DEFAULT false NOT NULL,
    initially_deferred boolean DEFAULT false NOT NULL,
    expression text,
    index bigint,
    to_object bigint,
    to_namespace_name text,
    to_object_name text,
    on_delete text,
    on_update text,
    match_kind text,
    "position" integer NOT NULL,
    CONSTRAINT constraints_check CHECK ((((kind = 'check'::text) = (expression IS NOT NULL)) OR (kind = 'exclusion'::text))),
    CONSTRAINT constraints_check1 CHECK (((kind <> 'foreign'::text) OR ((to_object IS NULL) = (to_object_name IS NOT NULL)))),
    CONSTRAINT constraints_kind_check CHECK ((kind = ANY (ARRAY['primary'::text, 'unique'::text, 'foreign'::text, 'check'::text, 'exclusion'::text, 'not_null'::text, 'identifier'::text]))),
    CONSTRAINT constraints_match_kind_check CHECK ((match_kind = ANY (ARRAY['simple'::text, 'full'::text, 'partial'::text]))),
    CONSTRAINT constraints_on_delete_check CHECK ((on_delete = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT constraints_on_update_check CHECK ((on_update = ANY (ARRAY['no_action'::text, 'restrict'::text, 'cascade'::text, 'set_null'::text, 'set_default'::text]))),
    CONSTRAINT constraints_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.constraints OWNER TO sf_owner;

--
-- Name: TABLE constraints; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.constraints IS 'a table''s keys and checks, a domain''s checks, and the links between tables: the ones the database enforces and the ones the design only draws.';


--
-- Name: COLUMN constraints.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.id IS 'issued by the database';


--
-- Name: COLUMN constraints.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.object IS 'the table or domain it is on';


--
-- Name: COLUMN constraints.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.name IS 'its constraint name; NULL for none';


--
-- Name: COLUMN constraints.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.kind IS 'what it is; identifier: columns that identify a row with no constraint enforcing it';


--
-- Name: COLUMN constraints.in_database; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.in_database IS 'false for a link the design draws that the database does not hold';


--
-- Name: COLUMN constraints.enforced; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.enforced IS 'false for one the database holds but does not enforce (NOT ENFORCED)';


--
-- Name: COLUMN constraints."deferrable"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints."deferrable" IS 'true when it may be checked at the end of a transaction';


--
-- Name: COLUMN constraints.initially_deferred; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.initially_deferred IS 'true when it is checked at the end unless said otherwise';


--
-- Name: COLUMN constraints.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.expression IS 'a check''s expression, in the engine''s SQL';


--
-- Name: COLUMN constraints.index; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.index IS 'the index that holds a key; NULL for none';


--
-- Name: COLUMN constraints.to_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.to_object IS 'the table a foreign key refers to: it cannot go while this row is here; NULL when it is outside the store';


--
-- Name: COLUMN constraints.to_namespace_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.to_namespace_name IS 'the namespace of a referred table outside the store, as written; NULL otherwise';


--
-- Name: COLUMN constraints.to_object_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.to_object_name IS 'a referred table outside the store, as written; NULL otherwise';


--
-- Name: COLUMN constraints.on_delete; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.on_delete IS 'what happens when the row referred to is deleted; NULL for the engine''s default';


--
-- Name: COLUMN constraints.on_update; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.on_update IS 'what happens when its key changes; NULL for the engine''s default';


--
-- Name: COLUMN constraints.match_kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints.match_kind IS 'how a key of several columns with some null matches; NULL for the engine''s default';


--
-- Name: COLUMN constraints."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.constraints."position" IS 'its place among the object''s constraints';


--
-- Name: broken_constraint_columns_on_their_tables; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_constraint_columns_on_their_tables AS
 SELECT 'constraint-columns-on-their-tables'::text AS rule,
    (x.id)::text AS id
   FROM (((cortex.constraint_columns x
     JOIN cortex.constraints k ON ((k.id = x."constraint")))
     JOIN cortex.columns c ON ((c.id = x."column")))
     LEFT JOIN cortex.columns t ON ((t.id = x.to_column)))
  WHERE ((c.object <> k.object) OR ((t.id IS NOT NULL) AND (t.object IS DISTINCT FROM k.to_object)));


ALTER VIEW cortex.broken_constraint_columns_on_their_tables OWNER TO sf_owner;

--
-- Name: VIEW broken_constraint_columns_on_their_tables; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_constraint_columns_on_their_tables IS 'Every column of a key or link is a column of its table, and every column a link refers to is a column of the table it refers to.';


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

COMMENT ON TABLE cortex.engine_features IS 'what a version of the database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it.';


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

COMMENT ON COLUMN cortex.engine_features.detail IS 'what a version alone does not say (enforced from 8.0.16); NULL for nothing';


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

COMMENT ON TABLE cortex.engine_versions IS 'the versions of the database the schema''s engine supports, in order, as the engine declares them.';


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
-- Name: index_parts; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.index_parts (
    id bigint NOT NULL,
    index bigint NOT NULL,
    "position" integer NOT NULL,
    "column" bigint,
    expression text,
    descending boolean DEFAULT false NOT NULL,
    included boolean DEFAULT false NOT NULL,
    CONSTRAINT index_parts_check CHECK ((("column" IS NULL) <> (expression IS NULL))),
    CONSTRAINT index_parts_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.index_parts OWNER TO sf_owner;

--
-- Name: TABLE index_parts; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.index_parts IS 'the parts of an index, in order: each a column or an expression, ordered or only included.';


--
-- Name: COLUMN index_parts.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.id IS 'issued by the database';


--
-- Name: COLUMN index_parts.index; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.index IS 'the index';


--
-- Name: COLUMN index_parts."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts."position" IS 'its place, 1 first';


--
-- Name: COLUMN index_parts."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts."column" IS 'the column indexed; NULL for an expression';


--
-- Name: COLUMN index_parts.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.expression IS 'the expression indexed, in the engine''s SQL; NULL for a column';


--
-- Name: COLUMN index_parts.descending; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.descending IS 'true when held descending';


--
-- Name: COLUMN index_parts.included; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.index_parts.included IS 'true for a column carried without being part of the order (INCLUDE)';


--
-- Name: indexes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.indexes (
    id bigint NOT NULL,
    object bigint NOT NULL,
    "position" integer NOT NULL,
    name text NOT NULL,
    "unique" boolean DEFAULT false NOT NULL,
    method text,
    condition text,
    comment text,
    CONSTRAINT indexes_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT indexes_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.indexes OWNER TO sf_owner;

--
-- Name: TABLE indexes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.indexes IS 'an index of a table, in the order the table lists them.';


--
-- Name: COLUMN indexes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.id IS 'issued by the database';


--
-- Name: COLUMN indexes.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.object IS 'the table it is on';


--
-- Name: COLUMN indexes."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes."position" IS 'its place among the table''s indexes: the server''s order, which information_schema does not give';


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

COMMENT ON COLUMN cortex.indexes.method IS 'how it is built, in the engine''s words (BTREE, FULLTEXT, SPATIAL, gin); NULL for the engine''s default';


--
-- Name: COLUMN indexes.condition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.condition IS 'the rows a partial index covers, in the engine''s SQL; NULL for all';


--
-- Name: COLUMN indexes.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.indexes.comment IS 'what it is for; NULL for none';


--
-- Name: broken_index_columns_on_their_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_index_columns_on_their_table AS
 SELECT 'index-columns-on-their-table'::text AS rule,
    (p.id)::text AS id
   FROM ((cortex.index_parts p
     JOIN cortex.indexes i ON ((i.id = p.index)))
     JOIN cortex.columns c ON ((c.id = p."column")))
  WHERE (c.object <> i.object);


ALTER VIEW cortex.broken_index_columns_on_their_table OWNER TO sf_owner;

--
-- Name: VIEW broken_index_columns_on_their_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_index_columns_on_their_table IS 'Every column an index orders by or carries is a column of the index''s table.';


--
-- Name: broken_links_have_columns; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_links_have_columns AS
 SELECT 'links-have-columns'::text AS rule,
    (id)::text AS id
   FROM cortex.constraints k
  WHERE ((kind = ANY (ARRAY['primary'::text, 'unique'::text, 'foreign'::text, 'identifier'::text])) AND (NOT (EXISTS ( SELECT 1
           FROM cortex.constraint_columns x
          WHERE (x."constraint" = k.id)))));


ALTER VIEW cortex.broken_links_have_columns OWNER TO sf_owner;

--
-- Name: VIEW broken_links_have_columns; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_links_have_columns IS 'Every key and every link has at least one column.';


--
-- Name: broken_one_current_branch; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_one_current_branch AS
 SELECT 'one-current-branch'::text AS rule,
    (id)::text AS id
   FROM cortex.branches b
  WHERE (( SELECT count(*) AS count
           FROM cortex.branches x
          WHERE x.current) <> 1);


ALTER VIEW cortex.broken_one_current_branch OWNER TO sf_owner;

--
-- Name: VIEW broken_one_current_branch; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_one_current_branch IS 'Once work has begun, exactly one branch is the one the design is on.';


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
    CONSTRAINT operations_kind_check CHECK ((kind ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT operations_summary_check CHECK ((length(summary) >= 1))
);


ALTER TABLE cortex.operations OWNER TO sf_owner;

--
-- Name: TABLE operations; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.operations IS 'what a turn did, one operation at a time, each of a kind the agent and the canvas name (added table orders).';


--
-- Name: COLUMN operations.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.id IS 'UUIDv7, issued by the database: its order is the order they were committed';


--
-- Name: COLUMN operations.turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.turn IS 'the turn it belongs to';


--
-- Name: COLUMN operations.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.kind IS 'what it is: one of the operation kinds';


--
-- Name: COLUMN operations.summary; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.summary IS 'what it did, in one line';


--
-- Name: COLUMN operations.at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.operations.at IS 'when it was committed';


--
-- Name: broken_operation_after_its_turn; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_operation_after_its_turn AS
 SELECT 'operation-after-its-turn'::text AS rule,
    (o.id)::text AS id
   FROM (cortex.operations o
     JOIN cortex.turns t ON ((t.id = o.turn)))
  WHERE (o.at < t.started_at);


ALTER VIEW cortex.broken_operation_after_its_turn OWNER TO sf_owner;

--
-- Name: VIEW broken_operation_after_its_turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_operation_after_its_turn IS 'An operation is committed no earlier than its turn began.';


--
-- Name: domains; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.domains (
    id bigint NOT NULL,
    base text NOT NULL,
    default_value text,
    nullable boolean DEFAULT true NOT NULL,
    "collation" text,
    CONSTRAINT domains_base_check CHECK ((length(base) >= 1))
);


ALTER TABLE cortex.domains OWNER TO sf_owner;

--
-- Name: TABLE domains; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.domains IS 'a type narrowed by a default, a not null and checks (its checks are in constraints).';


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
-- Name: COLUMN domains."collation"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.domains."collation" IS 'its collation where it is not its base type''s; NULL for that one';


--
-- Name: objects; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.objects (
    id bigint NOT NULL,
    namespace bigint NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    signature text DEFAULT ''::text NOT NULL,
    parent bigint,
    "position" numeric NOT NULL,
    comment text,
    notes text,
    CONSTRAINT objects_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT objects_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.objects OWNER TO sf_owner;

--
-- Name: TABLE objects; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds: tables, views, routines, triggers, events, sequences, types, whatever kinds the engine declares.';


--
-- Name: COLUMN objects.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.id IS 'issued by the database, kept when the name changes';


--
-- Name: COLUMN objects.namespace; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it';


--
-- Name: COLUMN objects.kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.kind IS 'one of the engine''s kinds: no other is accepted';


--
-- Name: COLUMN objects.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.name IS 'orders';


--
-- Name: COLUMN objects.signature; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.signature IS 'the argument types that tell an overloaded routine apart ((integer, text)); empty where a name is enough';


--
-- Name: COLUMN objects.parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.parent IS 'the object it belongs to: a trigger''s table; NULL for none';


--
-- Name: COLUMN objects."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects."position" IS 'its place among the objects, in the order made or read; an order key';


--
-- Name: COLUMN objects.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';


--
-- Name: COLUMN objects.notes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';


--
-- Name: partitionings; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.partitionings (
    id bigint NOT NULL,
    strategy text NOT NULL,
    expression text NOT NULL
);


ALTER TABLE cortex.partitionings OWNER TO sf_owner;

--
-- Name: TABLE partitionings; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.partitionings IS 'how a table is split into partitions.';


--
-- Name: COLUMN partitionings.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitionings.id IS 'the table split';


--
-- Name: COLUMN partitionings.strategy; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitionings.strategy IS 'the way rows are split, in the engine''s words (RANGE, LIST, HASH, KEY)';


--
-- Name: COLUMN partitionings.expression; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitionings.expression IS 'what it is split by, as the engine writes it (year(`d`), (taken))';


--
-- Name: routines; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.routines (
    id bigint NOT NULL,
    returns text,
    language text,
    deterministic boolean DEFAULT false NOT NULL,
    security text DEFAULT 'definer'::text NOT NULL,
    body text NOT NULL,
    CONSTRAINT routines_security_check CHECK ((security = ANY (ARRAY['definer'::text, 'invoker'::text])))
);


ALTER TABLE cortex.routines OWNER TO sf_owner;

--
-- Name: TABLE routines; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.routines IS 'a procedure or a function: what it returns, how it runs, and its body exactly as the server holds it.';


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

COMMENT ON COLUMN cortex.routines.language IS 'its language in the engine''s words (SQL, plpgsql); NULL for the engine''s own';


--
-- Name: COLUMN routines.deterministic; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.deterministic IS 'true when the same arguments always give the same result';


--
-- Name: COLUMN routines.security; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.security IS 'whose rights it runs with';


--
-- Name: COLUMN routines.body; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routines.body IS 'its body, exactly as the server holds it (SHOW CREATE, prosrc): information_schema''s copy is not it';


--
-- Name: sequences; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.sequences (
    id bigint NOT NULL,
    type text,
    start numeric,
    increment numeric,
    min_value numeric,
    max_value numeric,
    cache bigint,
    cycle boolean DEFAULT false NOT NULL,
    owned_by bigint,
    CONSTRAINT sequences_cache_check CHECK ((cache >= 1)),
    CONSTRAINT sequences_increment_check CHECK ((increment <> (0)::numeric))
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

COMMENT ON COLUMN cortex.sequences.start IS 'its first number; NULL for the engine''s default';


--
-- Name: COLUMN sequences.increment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.increment IS 'its step; NULL for the engine''s default';


--
-- Name: COLUMN sequences.min_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.min_value IS 'its smallest number; NULL for the engine''s default';


--
-- Name: COLUMN sequences.max_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.max_value IS 'its largest number; NULL for the engine''s default';


--
-- Name: COLUMN sequences.cache; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sequences.cache IS 'how many numbers are taken at a time; NULL for the engine''s default';


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
    id bigint NOT NULL,
    timing text NOT NULL,
    events jsonb NOT NULL,
    level text DEFAULT 'row'::text NOT NULL,
    condition text,
    body text,
    action_order integer DEFAULT 1 NOT NULL,
    CONSTRAINT triggers_action_order_check CHECK ((action_order >= 1)),
    CONSTRAINT triggers_level_check CHECK ((level = ANY (ARRAY['row'::text, 'statement'::text]))),
    CONSTRAINT triggers_timing_check CHECK ((timing = ANY (ARRAY['before'::text, 'after'::text, 'instead_of'::text])))
);


ALTER TABLE cortex.triggers OWNER TO sf_owner;

--
-- Name: TABLE triggers; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.triggers IS 'a trigger: when it fires, on which changes, for rows or statements, and what it runs.';


--
-- Name: COLUMN triggers.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.id IS 'the trigger; its table is the object''s parent';


--
-- Name: COLUMN triggers.timing; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.timing IS 'when it fires';


--
-- Name: COLUMN triggers.events; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.events IS 'the changes it fires on, in order: ["insert", "update"]';


--
-- Name: COLUMN triggers.level; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.level IS 'once per row or once per statement';


--
-- Name: COLUMN triggers.condition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.condition IS 'the rows it fires for, in the engine''s SQL; NULL for every row';


--
-- Name: COLUMN triggers.body; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.body IS 'the statements it runs, exactly as the server holds them; NULL where it calls a routine';


--
-- Name: COLUMN triggers.action_order; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.triggers.action_order IS 'its place among its table''s triggers of the same timing and change';


--
-- Name: views; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.views (
    id bigint NOT NULL,
    query text NOT NULL,
    check_option text,
    CONSTRAINT views_check_option_check CHECK ((check_option = ANY (ARRAY['local'::text, 'cascaded'::text]))),
    CONSTRAINT views_query_check CHECK ((length(query) >= 1))
);


ALTER TABLE cortex.views OWNER TO sf_owner;

--
-- Name: TABLE views; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.views IS 'a view''s query, as the server writes it, and what it guarantees of rows written through it.';


--
-- Name: COLUMN views.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.views.id IS 'the view';


--
-- Name: COLUMN views.query; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.views.query IS 'the query, as the server writes it';


--
-- Name: COLUMN views.check_option; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.views.check_option IS 'whether rows written through it must match it; NULL for none';


--
-- Name: broken_parts_of_their_kind; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_parts_of_their_kind AS
 SELECT 'parts-of-their-kind'::text AS rule,
    (x.id)::text AS id
   FROM (( SELECT routines.id,
            ARRAY['procedure'::text, 'function'::text] AS kinds
           FROM cortex.routines
        UNION ALL
         SELECT views.id,
            ARRAY['view'::text, 'materialized_view'::text] AS "array"
           FROM cortex.views
        UNION ALL
         SELECT triggers.id,
            ARRAY['trigger'::text] AS "array"
           FROM cortex.triggers
        UNION ALL
         SELECT sequences.id,
            ARRAY['sequence'::text] AS "array"
           FROM cortex.sequences
        UNION ALL
         SELECT partitionings.id,
            ARRAY['table'::text] AS "array"
           FROM cortex.partitionings
        UNION ALL
         SELECT domains.id,
            ARRAY['domain'::text] AS "array"
           FROM cortex.domains) x
     JOIN cortex.objects o ON ((o.id = x.id)))
  WHERE (o.kind <> ALL (x.kinds));


ALTER VIEW cortex.broken_parts_of_their_kind OWNER TO sf_owner;

--
-- Name: VIEW broken_parts_of_their_kind; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_parts_of_their_kind IS 'A routine is a procedure or a function, a view a view or a materialized view, a trigger a trigger, a sequence a sequence, a partitioning on a table, a domain a domain.';


--
-- Name: broken_primary_key_columns_not_null; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_primary_key_columns_not_null AS
 SELECT 'primary-key-columns-not-null'::text AS rule,
    (c.id)::text AS id
   FROM ((cortex.constraint_columns x
     JOIN cortex.constraints k ON ((k.id = x."constraint")))
     JOIN cortex.columns c ON ((c.id = x."column")))
  WHERE ((k.kind = 'primary'::text) AND c.nullable);


ALTER VIEW cortex.broken_primary_key_columns_not_null OWNER TO sf_owner;

--
-- Name: VIEW broken_primary_key_columns_not_null; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_primary_key_columns_not_null IS 'Every column of a primary key holds no null.';


--
-- Name: row_changes; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.row_changes (
    id bigint NOT NULL,
    operation uuid NOT NULL,
    table_name text NOT NULL,
    row_id bigint NOT NULL,
    action text NOT NULL,
    before jsonb,
    after jsonb,
    CONSTRAINT row_changes_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT row_changes_check CHECK (((action = 'insert'::text) = (before IS NULL))),
    CONSTRAINT row_changes_check1 CHECK (((action = 'delete'::text) = (after IS NULL))),
    CONSTRAINT row_changes_table_name_check CHECK ((table_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text))
);


ALTER TABLE cortex.row_changes OWNER TO sf_owner;

--
-- Name: TABLE row_changes; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.row_changes IS 'the log: every row an operation inserted, updated or deleted, in any table of the cortex and the engines, with its values before and after; appended, never edited. Undo applies them backwards, redo forwards.';


--
-- Name: COLUMN row_changes.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.id IS 'issued by the database: its order is the order the rows changed in';


--
-- Name: COLUMN row_changes.operation; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.operation IS 'the operation';


--
-- Name: COLUMN row_changes.table_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.table_name IS 'the table, with its namespace (cortex.objects, engine_mysql.tables)';


--
-- Name: COLUMN row_changes.row_id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.row_id IS 'the row''s id';


--
-- Name: COLUMN row_changes.action; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.action IS 'what happened to the row';


--
-- Name: COLUMN row_changes.before; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.before IS 'for an update, the values it changed as they were; for a delete, the whole row; NULL for an insert';


--
-- Name: COLUMN row_changes.after; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.row_changes.after IS 'for an update, the values it changed as they are; for an insert, the whole row; NULL for a delete';


--
-- Name: broken_row_changes_name_tables_of_the_database; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_row_changes_name_tables_of_the_database AS
 SELECT 'row-changes-name-tables-of-the-database'::text AS rule,
    (id)::text AS id
   FROM cortex.row_changes r
  WHERE (to_regclass(table_name) IS NULL);


ALTER VIEW cortex.broken_row_changes_name_tables_of_the_database OWNER TO sf_owner;

--
-- Name: VIEW broken_row_changes_name_tables_of_the_database; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_row_changes_name_tables_of_the_database IS 'The log names only tables of this database, each with its namespace.';


--
-- Name: sort_fields; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.sort_fields (
    id bigint NOT NULL,
    object bigint NOT NULL,
    "position" integer NOT NULL,
    "column" bigint NOT NULL,
    transform text,
    descending boolean DEFAULT false NOT NULL,
    CONSTRAINT sort_fields_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.sort_fields OWNER TO sf_owner;

--
-- Name: TABLE sort_fields; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.sort_fields IS 'the order a table''s rows are written in (a sort order, a clustering).';


--
-- Name: COLUMN sort_fields.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.id IS 'issued by the database';


--
-- Name: COLUMN sort_fields.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.object IS 'the table';


--
-- Name: COLUMN sort_fields."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields."position" IS 'its place, 1 first';


--
-- Name: COLUMN sort_fields."column"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields."column" IS 'the column ordered by';


--
-- Name: COLUMN sort_fields.transform; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.transform IS 'the transform, in the engine''s words; NULL for the value itself';


--
-- Name: COLUMN sort_fields.descending; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.sort_fields.descending IS 'true when descending';


--
-- Name: broken_sort_columns_on_their_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_sort_columns_on_their_table AS
 SELECT 'sort-columns-on-their-table'::text AS rule,
    (s.id)::text AS id
   FROM (cortex.sort_fields s
     JOIN cortex.columns c ON ((c.id = s."column")))
  WHERE (c.object <> s.object);


ALTER VIEW cortex.broken_sort_columns_on_their_table OWNER TO sf_owner;

--
-- Name: VIEW broken_sort_columns_on_their_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_sort_columns_on_their_table IS 'Every column a table''s rows are ordered by is a column of that table.';


--
-- Name: broken_triggers_on_a_table; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_triggers_on_a_table AS
 SELECT 'triggers-on-a-table'::text AS rule,
    (o.id)::text AS id
   FROM (cortex.objects o
     LEFT JOIN cortex.objects t ON ((t.id = o.parent)))
  WHERE ((o.kind = 'trigger'::text) AND ((t.id IS NULL) OR (t.kind <> ALL (ARRAY['table'::text, 'view'::text])) OR (t.namespace <> o.namespace)));


ALTER VIEW cortex.broken_triggers_on_a_table OWNER TO sf_owner;

--
-- Name: VIEW broken_triggers_on_a_table; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_triggers_on_a_table IS 'Every trigger belongs to a table or a view of its namespace.';


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

COMMENT ON VIEW cortex.broken_turn_takes_back_an_earlier_turn IS 'A turn that undoes takes back a turn made before it.';


--
-- Name: broken_turns_follow_their_parent; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_turns_follow_their_parent AS
 SELECT 'turns-follow-their-parent'::text AS rule,
    (t.id)::text AS id
   FROM (cortex.turns t
     JOIN cortex.turns p ON ((p.id = t.parent)))
  WHERE (p.id >= t.id);


ALTER VIEW cortex.broken_turns_follow_their_parent OWNER TO sf_owner;

--
-- Name: VIEW broken_turns_follow_their_parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_turns_follow_their_parent IS 'A turn follows a turn made before it.';


--
-- Name: locked_versions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.locked_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    number integer NOT NULL,
    turn uuid NOT NULL,
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

COMMENT ON TABLE cortex.locked_versions IS 'a locked version of the schema: the log up to one turn, its number and its hash.';


--
-- Name: COLUMN locked_versions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.id IS 'UUIDv7, issued when it is locked';


--
-- Name: COLUMN locked_versions.number; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.number IS 'v1, v2, v3: one more than the version before';


--
-- Name: COLUMN locked_versions.turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.turn IS 'the last turn it holds: moving the design to it gives the version';


--
-- Name: COLUMN locked_versions.hash; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.hash IS 'SHA-256 of the version''s design, hex: the design at that turn always hashes to it';


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

COMMENT ON COLUMN cortex.locked_versions.git_commit IS 'the commit its definitions were written in; NULL outside a git repository';


--
-- Name: COLUMN locked_versions.git_tag; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.locked_versions.git_tag IS 'the tag of that commit; NULL outside a git repository';


--
-- Name: broken_versions_follow_the_log; Type: VIEW; Schema: cortex; Owner: sf_owner
--

CREATE VIEW cortex.broken_versions_follow_the_log AS
 SELECT 'versions-follow-the-log'::text AS rule,
    (id)::text AS id
   FROM cortex.locked_versions b
  WHERE (((number > 1) AND (NOT (EXISTS ( SELECT 1
           FROM cortex.locked_versions a
          WHERE (a.number = (b.number - 1)))))) OR (EXISTS ( SELECT 1
           FROM cortex.locked_versions a
          WHERE ((a.number = (b.number - 1)) AND (b.turn <= a.turn)))));


ALTER VIEW cortex.broken_versions_follow_the_log OWNER TO sf_owner;

--
-- Name: VIEW broken_versions_follow_the_log; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON VIEW cortex.broken_versions_follow_the_log IS 'Versions are numbered from 1 without a gap, and a higher version holds a later turn.';


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

COMMENT ON TABLE cortex.catalog_sources IS 'what the engine''s live read asks a server of each version, what it gives, and the grant it needs.';


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

COMMENT ON COLUMN cortex.catalog_sources.source IS 'the catalog table or statement, as the server names it (SHOW CREATE TABLE)';


--
-- Name: COLUMN catalog_sources.gives; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.gives IS 'what the read takes from it (routines and their bodies)';


--
-- Name: COLUMN catalog_sources.needs; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.catalog_sources.needs IS 'the grant it needs, as the server writes it; NULL for none beyond the database''s';


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
    id bigint NOT NULL,
    always boolean DEFAULT false NOT NULL,
    sequence bigint
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

COMMENT ON COLUMN cortex.column_identities.always IS 'true when a value can never be given (ALWAYS); false for BY DEFAULT and for MySQL''s AUTO_INCREMENT';


--
-- Name: COLUMN column_identities.sequence; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.column_identities.sequence IS 'the sequence that numbers it, where the engine makes one; NULL for none';


--
-- Name: columns_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.columns ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.columns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: constraint_columns_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.constraint_columns ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.constraint_columns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: constraints_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.constraints ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.constraints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dependencies; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.dependencies (
    id bigint NOT NULL,
    object bigint NOT NULL,
    uses bigint NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT dependencies_check CHECK ((object <> uses)),
    CONSTRAINT dependencies_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.dependencies OWNER TO sf_owner;

--
-- Name: TABLE dependencies; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.dependencies IS 'what an object uses: a view''s tables, a MERGE table''s tables, a routine''s tables where the engine says. A used object cannot be dropped before what uses it, and an edit names what it would break; a body is text, so a rename never reaches into it.';


--
-- Name: COLUMN dependencies.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.dependencies.id IS 'issued by the database';


--
-- Name: COLUMN dependencies.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.dependencies.object IS 'the object that uses';


--
-- Name: COLUMN dependencies.uses; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.dependencies.uses IS 'the object used: it cannot go while this row is here';


--
-- Name: COLUMN dependencies."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.dependencies."position" IS 'its place, 1 first';


--
-- Name: dependencies_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.dependencies ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.dependencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: enum_values; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.enum_values (
    id bigint NOT NULL,
    object bigint NOT NULL,
    "position" integer NOT NULL,
    value text NOT NULL,
    CONSTRAINT enum_values_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.enum_values OWNER TO sf_owner;

--
-- Name: TABLE enum_values; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.enum_values IS 'the values of an enumerated type, in order.';


--
-- Name: COLUMN enum_values.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.id IS 'issued by the database';


--
-- Name: COLUMN enum_values.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.object IS 'the type';


--
-- Name: COLUMN enum_values."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values."position" IS 'its place, 1 first';


--
-- Name: COLUMN enum_values.value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.enum_values.value IS 'the value';


--
-- Name: enum_values_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.enum_values ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.enum_values_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: index_parts_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.index_parts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.index_parts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: indexes_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.indexes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.indexes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: namespaces; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.namespaces (
    id bigint NOT NULL,
    parent bigint,
    name text NOT NULL,
    "position" numeric NOT NULL,
    comment text,
    CONSTRAINT namespaces_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT namespaces_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.namespaces OWNER TO sf_owner;

--
-- Name: TABLE namespaces; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.namespaces IS 'the levels that hold objects, each under its parent or at the top: a MySQL database; a PostgreSQL database and its schemas.';


--
-- Name: COLUMN namespaces.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.id IS 'issued by the database, kept when the name changes';


--
-- Name: COLUMN namespaces.parent; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.parent IS 'the namespace it sits in; NULL at the top';


--
-- Name: COLUMN namespaces.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.name IS 'sales';


--
-- Name: COLUMN namespaces."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces."position" IS 'its place among the namespaces, in the order made or read; an order key';


--
-- Name: COLUMN namespaces.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.namespaces.comment IS 'what it holds: written into its SQL';


--
-- Name: namespaces_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.namespaces ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.namespaces_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


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

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object this schema''s engine has, as the engine declares them; no other kind is accepted.';


--
-- Name: COLUMN object_kinds.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds.id IS 'as an object names its kind (table, view, procedure, materialized_view)';


--
-- Name: COLUMN object_kinds.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';


--
-- Name: COLUMN object_kinds."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_kinds."position" IS 'its place in the engine''s declaration, for listing in the engine''s order';


--
-- Name: object_tags; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.object_tags (
    id bigint NOT NULL,
    object bigint NOT NULL,
    "position" integer NOT NULL,
    tag text NOT NULL,
    CONSTRAINT object_tags_position_check CHECK (("position" >= 1)),
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

COMMENT ON COLUMN cortex.object_tags.id IS 'issued by the database';


--
-- Name: COLUMN object_tags.object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags.object IS 'the object tagged';


--
-- Name: COLUMN object_tags."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags."position" IS 'its place, 1 first';


--
-- Name: COLUMN object_tags.tag; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.object_tags.tag IS 'the tag';


--
-- Name: object_tags_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.object_tags ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.object_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: objects_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.objects ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.objects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: partitions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.partitions (
    id bigint NOT NULL,
    partitioning bigint NOT NULL,
    "position" integer NOT NULL,
    name text NOT NULL,
    bounds text,
    table_object bigint,
    comment text,
    CONSTRAINT partitions_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT partitions_position_check CHECK (("position" >= 1))
);


ALTER TABLE cortex.partitions OWNER TO sf_owner;

--
-- Name: TABLE partitions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.partitions IS 'the partitions of a table, in order, with their bounds; where the engine makes a partition a table of its own, that table.';


--
-- Name: COLUMN partitions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.id IS 'issued by the database';


--
-- Name: COLUMN partitions.partitioning; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.partitioning IS 'the partitioning';


--
-- Name: COLUMN partitions."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions."position" IS 'its place, 1 first';


--
-- Name: COLUMN partitions.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.name IS 'its name';


--
-- Name: COLUMN partitions.bounds; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.bounds IS 'its bounds as the engine writes them (2025, FOR VALUES IN (''east'')); NULL where the strategy gives none';


--
-- Name: COLUMN partitions.table_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.table_object IS 'the table it is, where the engine makes partitions tables (PostgreSQL); NULL otherwise';


--
-- Name: COLUMN partitions.comment; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.partitions.comment IS 'what it holds; NULL for none';


--
-- Name: partitions_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.partitions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.partitions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: required_extensions; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.required_extensions (
    id bigint NOT NULL,
    name text NOT NULL,
    namespace_name text,
    version text,
    "position" numeric NOT NULL,
    CONSTRAINT required_extensions_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT required_extensions_position_check CHECK (("position" > (0)::numeric))
);


ALTER TABLE cortex.required_extensions OWNER TO sf_owner;

--
-- Name: TABLE required_extensions; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.required_extensions IS 'what the database must have installed for this schema (an extension, a plugin), in order.';


--
-- Name: COLUMN required_extensions.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions.id IS 'issued by the database';


--
-- Name: COLUMN required_extensions.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions.name IS 'its name, in the engine''s words (postgis)';


--
-- Name: COLUMN required_extensions.namespace_name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions.namespace_name IS 'the namespace it is installed into, as the server names it; NULL for the engine''s default';


--
-- Name: COLUMN required_extensions.version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions.version IS 'the version installed; NULL for the newest';


--
-- Name: COLUMN required_extensions."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.required_extensions."position" IS 'its place in the schema''s list of requirements; an order key';


--
-- Name: required_extensions_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.required_extensions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.required_extensions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: routine_parameters; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.routine_parameters (
    id bigint NOT NULL,
    routine bigint NOT NULL,
    "position" integer NOT NULL,
    name text,
    type text NOT NULL,
    mode text DEFAULT 'in'::text NOT NULL,
    default_value text,
    CONSTRAINT routine_parameters_mode_check CHECK ((mode = ANY (ARRAY['in'::text, 'out'::text, 'in_out'::text, 'variadic'::text, 'table'::text]))),
    CONSTRAINT routine_parameters_position_check CHECK (("position" >= 1)),
    CONSTRAINT routine_parameters_type_check CHECK ((length(type) >= 1))
);


ALTER TABLE cortex.routine_parameters OWNER TO sf_owner;

--
-- Name: TABLE routine_parameters; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.routine_parameters IS 'the parameters of a routine, in order, as the server reads them: for search and the canvas.';


--
-- Name: COLUMN routine_parameters.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.id IS 'issued by the database';


--
-- Name: COLUMN routine_parameters.routine; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.routine IS 'the routine';


--
-- Name: COLUMN routine_parameters."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters."position" IS 'its place, 1 first';


--
-- Name: COLUMN routine_parameters.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.name IS 'its name; NULL for an unnamed one';


--
-- Name: COLUMN routine_parameters.type; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.type IS 'its type, as the engine writes it';


--
-- Name: COLUMN routine_parameters.mode; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.mode IS 'how it is passed; table: a column of what a function returns';


--
-- Name: COLUMN routine_parameters.default_value; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.routine_parameters.default_value IS 'its default, in the engine''s SQL; NULL for none';


--
-- Name: routine_parameters_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.routine_parameters ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.routine_parameters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: row_changes_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.row_changes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.row_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: savepoints; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.savepoints (
    id bigint NOT NULL,
    name text NOT NULL,
    turn uuid NOT NULL,
    made_by text NOT NULL,
    made_at timestamp with time zone NOT NULL,
    CONSTRAINT savepoints_made_by_check CHECK ((length(made_by) >= 1)),
    CONSTRAINT savepoints_name_check CHECK ((length(name) >= 1))
);


ALTER TABLE cortex.savepoints OWNER TO sf_owner;

--
-- Name: TABLE savepoints; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.savepoints IS 'a turn someone named, to open or restore later.';


--
-- Name: COLUMN savepoints.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.savepoints.id IS 'issued by the database';


--
-- Name: COLUMN savepoints.name; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.savepoints.name IS 'as people call it';


--
-- Name: COLUMN savepoints.turn; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.savepoints.turn IS 'the turn it marks';


--
-- Name: COLUMN savepoints.made_by; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.savepoints.made_by IS 'who named it';


--
-- Name: COLUMN savepoints.made_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.savepoints.made_at IS 'when';


--
-- Name: savepoints_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.savepoints ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.savepoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_identity; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.schema_identity (
    id uuid NOT NULL,
    name text NOT NULL,
    engine text NOT NULL,
    engine_version text NOT NULL,
    comment text,
    created_at timestamp with time zone NOT NULL,
    one boolean DEFAULT true NOT NULL,
    CONSTRAINT schema_identity_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT schema_identity_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100))),
    CONSTRAINT schema_identity_one_check CHECK (one)
);


ALTER TABLE cortex.schema_identity OWNER TO sf_owner;

--
-- Name: TABLE schema_identity; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.schema_identity IS 'the schema this database holds, exactly one row.';


--
-- Name: COLUMN schema_identity.id; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.id IS 'UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema';


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
-- Name: COLUMN schema_identity.created_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.created_at IS 'when the database was made';


--
-- Name: COLUMN schema_identity.one; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.schema_identity.one IS 'keeps the table to one row';


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
    CONSTRAINT schema_migrations_owner_check CHECK ((owner ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT schema_migrations_version_check CHECK ((version >= 1))
);


ALTER TABLE cortex.schema_migrations OWNER TO sf_owner;

--
-- Name: TABLE schema_migrations; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON TABLE cortex.schema_migrations IS 'every migration applied to this schema''s database, by its owner.';


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
-- Name: sort_fields_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.sort_fields ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.sort_fields_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: source_reads; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.source_reads (
    id uuid DEFAULT uuidv7() NOT NULL,
    turn uuid,
    connection_id uuid NOT NULL,
    connection_name text NOT NULL,
    database_name text NOT NULL,
    scope jsonb NOT NULL,
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

COMMENT ON TABLE cortex.source_reads IS 'each read of a live database for this schema: from which saved connection, which server, as whom, and when.';


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
-- Name: COLUMN source_reads.scope; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.scope IS 'what the person asked to read: everything, or the parts (definitions, statistics groups) and objects chosen';


--
-- Name: COLUMN source_reads.server_version; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.server_version IS 'the version the server gave (8.4.13)';


--
-- Name: COLUMN source_reads.server_edition; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.server_edition IS 'what the server says it is beyond its version; NULL when it says nothing';


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

COMMENT ON COLUMN cortex.source_reads.missing_grants IS 'the grants the account lacked, and so what was not read; NULL for none';


--
-- Name: COLUMN source_reads.started_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.started_at IS 'when the read began';


--
-- Name: COLUMN source_reads.ended_at; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.source_reads.ended_at IS 'when it ended; NULL while it runs';


--
-- Name: verbatim_statements; Type: TABLE; Schema: cortex; Owner: sf_owner
--

CREATE TABLE cortex.verbatim_statements (
    id bigint NOT NULL,
    "position" numeric NOT NULL,
    kind text NOT NULL,
    text text NOT NULL,
    after_namespace bigint,
    after_object bigint,
    CONSTRAINT verbatim_statements_check CHECK (((after_namespace IS NULL) OR (after_object IS NULL))),
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

COMMENT ON COLUMN cortex.verbatim_statements.id IS 'issued by the database';


--
-- Name: COLUMN verbatim_statements."position"; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements."position" IS 'its place in the order it was read; an order key';


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

COMMENT ON COLUMN cortex.verbatim_statements.after_namespace IS 'the namespace it is written after; NULL when it follows an object or the start';


--
-- Name: COLUMN verbatim_statements.after_object; Type: COMMENT; Schema: cortex; Owner: sf_owner
--

COMMENT ON COLUMN cortex.verbatim_statements.after_object IS 'the object it is written after; NULL when it follows a namespace or the start';


--
-- Name: verbatim_statements_id_seq; Type: SEQUENCE; Schema: cortex; Owner: sf_owner
--

ALTER TABLE cortex.verbatim_statements ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cortex.verbatim_statements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: relations; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.relations (
    id bigint NOT NULL,
    persistence text DEFAULT 'permanent'::text NOT NULL,
    options jsonb,
    access_method text,
    owner text,
    acl jsonb,
    row_security boolean DEFAULT false NOT NULL,
    force_row_security boolean DEFAULT false NOT NULL,
    replica_identity text DEFAULT 'default'::text NOT NULL,
    populated boolean DEFAULT true NOT NULL,
    CONSTRAINT relations_persistence_check CHECK ((persistence = ANY (ARRAY['permanent'::text, 'unlogged'::text, 'temporary'::text]))),
    CONSTRAINT relations_replica_identity_check CHECK ((replica_identity = ANY (ARRAY['default'::text, 'nothing'::text, 'full'::text, 'index'::text])))
);


ALTER TABLE engine_postgresql.relations OWNER TO sf_owner;

--
-- Name: TABLE relations; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.relations IS 'what PostgreSQL says of a table, view, materialized view or sequence beyond the cortex.';


--
-- Name: COLUMN relations.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.id IS 'the relation';


--
-- Name: COLUMN relations.persistence; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.persistence IS 'how it is kept';


--
-- Name: COLUMN relations.options; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.options IS 'its storage options as the server writes them (["fillfactor=70"]); NULL for none';


--
-- Name: COLUMN relations.access_method; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.access_method IS 'its table access method (heap); NULL for the default';


--
-- Name: COLUMN relations.owner; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.owner IS 'its owner, by role name; NULL for the one the schema is written as';


--
-- Name: COLUMN relations.acl; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.acl IS 'its privileges, as the server writes them; NULL for the defaults';


--
-- Name: COLUMN relations.row_security; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.row_security IS 'true when its policies apply (ENABLE ROW LEVEL SECURITY)';


--
-- Name: COLUMN relations.force_row_security; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.force_row_security IS 'true when they apply to its owner too';


--
-- Name: COLUMN relations.replica_identity; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.replica_identity IS 'what identifies a row to logical replication';


--
-- Name: COLUMN relations.populated; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.relations.populated IS 'for a materialized view, false when made WITH NO DATA';


--
-- Name: types; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.types (
    id bigint NOT NULL,
    owner text,
    acl jsonb,
    range_subtype text,
    multirange text
);


ALTER TABLE engine_postgresql.types OWNER TO sf_owner;

--
-- Name: TABLE types; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.types IS 'an enum, composite, domain or range type''s PostgreSQL facts beyond the cortex.';


--
-- Name: COLUMN types.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.types.id IS 'the type';


--
-- Name: COLUMN types.owner; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.types.owner IS 'its owner, by role name; NULL for the one the schema is written as';


--
-- Name: COLUMN types.acl; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.types.acl IS 'its privileges; NULL for the defaults';


--
-- Name: COLUMN types.range_subtype; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.types.range_subtype IS 'a range type''s element type; NULL otherwise';


--
-- Name: COLUMN types.multirange; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.types.multirange IS 'a range type''s multirange type name; NULL otherwise';


--
-- Name: broken_parts_of_their_kind; Type: VIEW; Schema: engine_postgresql; Owner: sf_owner
--

CREATE VIEW engine_postgresql.broken_parts_of_their_kind AS
 SELECT 'parts-of-their-kind'::text AS rule,
    (x.id)::text AS id
   FROM (( SELECT relations.id,
            ARRAY['table'::text, 'view'::text, 'materialized_view'::text, 'sequence'::text] AS kinds
           FROM engine_postgresql.relations
        UNION ALL
         SELECT types.id,
            ARRAY['enum'::text, 'composite'::text, 'domain'::text, 'range'::text] AS "array"
           FROM engine_postgresql.types) x
     JOIN cortex.objects o ON ((o.id = x.id)))
  WHERE (o.kind <> ALL (x.kinds));


ALTER VIEW engine_postgresql.broken_parts_of_their_kind OWNER TO sf_owner;

--
-- Name: VIEW broken_parts_of_their_kind; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON VIEW engine_postgresql.broken_parts_of_their_kind IS 'A relation''s facts are a table''s, a view''s, a materialized view''s or a sequence''s, and a type''s facts a type''s.';


--
-- Name: broken_relations_have_their_facts; Type: VIEW; Schema: engine_postgresql; Owner: sf_owner
--

CREATE VIEW engine_postgresql.broken_relations_have_their_facts AS
 SELECT 'relations-have-their-facts'::text AS rule,
    (id)::text AS id
   FROM cortex.objects o
  WHERE ((kind = ANY (ARRAY['table'::text, 'view'::text, 'materialized_view'::text, 'sequence'::text])) AND (NOT (EXISTS ( SELECT 1
           FROM engine_postgresql.relations r
          WHERE (r.id = o.id)))));


ALTER VIEW engine_postgresql.broken_relations_have_their_facts OWNER TO sf_owner;

--
-- Name: VIEW broken_relations_have_their_facts; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON VIEW engine_postgresql.broken_relations_have_their_facts IS 'Every table, view, materialized view and sequence has its persistence, owner and privileges.';


--
-- Name: collations; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.collations (
    id bigint NOT NULL,
    namespace bigint NOT NULL,
    name text NOT NULL,
    provider text NOT NULL,
    locale text,
    lc_collate text,
    lc_ctype text,
    deterministic boolean DEFAULT true NOT NULL,
    comment text,
    CONSTRAINT collations_name_check CHECK ((length(name) >= 1)),
    CONSTRAINT collations_provider_check CHECK ((provider = ANY (ARRAY['icu'::text, 'libc'::text, 'builtin'::text])))
);


ALTER TABLE engine_postgresql.collations OWNER TO sf_owner;

--
-- Name: TABLE collations; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.collations IS 'a collation the schema defines.';


--
-- Name: COLUMN collations.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.id IS 'issued by the database';


--
-- Name: COLUMN collations.namespace; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.namespace IS 'the schema it is in';


--
-- Name: COLUMN collations.name; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.name IS 'its name';


--
-- Name: COLUMN collations.provider; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.provider IS 'where its rules come from';


--
-- Name: COLUMN collations.locale; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.locale IS 'its locale (und-u-ks-level2); NULL for libc, which names lc_collate and lc_ctype';


--
-- Name: COLUMN collations.lc_collate; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.lc_collate IS 'libc''s collate locale; NULL otherwise';


--
-- Name: COLUMN collations.lc_ctype; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.lc_ctype IS 'libc''s character-class locale; NULL otherwise';


--
-- Name: COLUMN collations.deterministic; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.deterministic IS 'false when strings unequal byte for byte may compare equal';


--
-- Name: COLUMN collations.comment; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.collations.comment IS 'what it is for; NULL for none';


--
-- Name: collations_id_seq; Type: SEQUENCE; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE engine_postgresql.collations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME engine_postgresql.collations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: columns; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.columns (
    id bigint NOT NULL,
    is_local boolean DEFAULT true NOT NULL,
    inherit_count integer DEFAULT 0 NOT NULL,
    options jsonb,
    acl jsonb,
    CONSTRAINT columns_inherit_count_check CHECK ((inherit_count >= 0))
);


ALTER TABLE engine_postgresql.columns OWNER TO sf_owner;

--
-- Name: TABLE columns; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.columns IS 'what PostgreSQL says of a column beyond the cortex; a row only where it says something.';


--
-- Name: COLUMN columns.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.columns.id IS 'the column';


--
-- Name: COLUMN columns.is_local; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.columns.is_local IS 'false when it comes from a parent table only';


--
-- Name: COLUMN columns.inherit_count; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.columns.inherit_count IS 'how many parents it comes from';


--
-- Name: COLUMN columns.options; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.columns.options IS 'its options as the server writes them; NULL for none';


--
-- Name: COLUMN columns.acl; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.columns.acl IS 'its column privileges; NULL for none';


--
-- Name: constraints; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.constraints (
    id bigint NOT NULL,
    validated boolean DEFAULT true NOT NULL,
    no_inherit boolean DEFAULT false NOT NULL,
    is_local boolean DEFAULT true NOT NULL,
    inherit_count integer DEFAULT 0 NOT NULL,
    operators jsonb,
    CONSTRAINT constraints_inherit_count_check CHECK ((inherit_count >= 0))
);


ALTER TABLE engine_postgresql.constraints OWNER TO sf_owner;

--
-- Name: TABLE constraints; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.constraints IS 'what PostgreSQL says of a constraint beyond the cortex; a row only where it says something.';


--
-- Name: COLUMN constraints.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.id IS 'the constraint';


--
-- Name: COLUMN constraints.validated; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.validated IS 'false when made NOT VALID: existing rows are not checked';


--
-- Name: COLUMN constraints.no_inherit; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.no_inherit IS 'true when it does not pass to child tables';


--
-- Name: COLUMN constraints.is_local; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.is_local IS 'false when it comes from a parent table only';


--
-- Name: COLUMN constraints.inherit_count; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.inherit_count IS 'how many parents it comes from';


--
-- Name: COLUMN constraints.operators; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.constraints.operators IS 'an exclusion''s operators, one per part (["=", "&&"]); NULL otherwise';


--
-- Name: index_parts; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.index_parts (
    id bigint NOT NULL,
    nulls_first boolean DEFAULT false NOT NULL,
    operator_class text,
    "collation" text
);


ALTER TABLE engine_postgresql.index_parts OWNER TO sf_owner;

--
-- Name: TABLE index_parts; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.index_parts IS 'how one part of an index is ordered and compared, where it is not the default.';


--
-- Name: COLUMN index_parts.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.index_parts.id IS 'the index part';


--
-- Name: COLUMN index_parts.nulls_first; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.index_parts.nulls_first IS 'true when nulls sort first';


--
-- Name: COLUMN index_parts.operator_class; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.index_parts.operator_class IS 'its operator class where it is not the default for its type, as the server writes it (gist_trgm_ops); NULL for the default';


--
-- Name: COLUMN index_parts."collation"; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.index_parts."collation" IS 'its collation where it is not its column''s or expression''s; NULL for that one';


--
-- Name: indexes; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.indexes (
    id bigint NOT NULL,
    nulls_not_distinct boolean DEFAULT false NOT NULL,
    options jsonb,
    parent bigint
);


ALTER TABLE engine_postgresql.indexes OWNER TO sf_owner;

--
-- Name: TABLE indexes; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.indexes IS 'what PostgreSQL says of an index beyond the cortex; a row only where it says something.';


--
-- Name: COLUMN indexes.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.indexes.id IS 'the index';


--
-- Name: COLUMN indexes.nulls_not_distinct; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.indexes.nulls_not_distinct IS 'true when nulls count as equal (15 and later)';


--
-- Name: COLUMN indexes.options; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.indexes.options IS 'its storage options as the server writes them (["pages_per_range=32"]); NULL for none';


--
-- Name: COLUMN indexes.parent; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.indexes.parent IS 'the partitioned table''s index it is part of; NULL for none';


--
-- Name: inheritance; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.inheritance (
    id bigint NOT NULL,
    object bigint NOT NULL,
    parent bigint NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT inheritance_position_check CHECK (("position" >= 1))
);


ALTER TABLE engine_postgresql.inheritance OWNER TO sf_owner;

--
-- Name: TABLE inheritance; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.inheritance IS 'the tables a table inherits from, in order (INHERITS); partitions are cortex.partitions.';


--
-- Name: COLUMN inheritance.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.inheritance.id IS 'issued by the database';


--
-- Name: COLUMN inheritance.object; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.inheritance.object IS 'the table that inherits';


--
-- Name: COLUMN inheritance.parent; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.inheritance.parent IS 'the table inherited from: it cannot go first';


--
-- Name: COLUMN inheritance."position"; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.inheritance."position" IS 'its place, 1 first';


--
-- Name: inheritance_id_seq; Type: SEQUENCE; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE engine_postgresql.inheritance ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME engine_postgresql.inheritance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: namespaces; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.namespaces (
    id bigint NOT NULL,
    owner text,
    acl jsonb
);


ALTER TABLE engine_postgresql.namespaces OWNER TO sf_owner;

--
-- Name: TABLE namespaces; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.namespaces IS 'who owns a PostgreSQL schema and who may use it.';


--
-- Name: COLUMN namespaces.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.namespaces.id IS 'the schema';


--
-- Name: COLUMN namespaces.owner; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.namespaces.owner IS 'its owner, by role name; NULL for the one the schema is written as';


--
-- Name: COLUMN namespaces.acl; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.namespaces.acl IS 'its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults';


--
-- Name: policies; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.policies (
    id bigint NOT NULL,
    object bigint NOT NULL,
    name text NOT NULL,
    permissive boolean DEFAULT true NOT NULL,
    command text NOT NULL,
    roles jsonb NOT NULL,
    using_expression text,
    check_expression text,
    CONSTRAINT policies_command_check CHECK ((command = ANY (ARRAY['ALL'::text, 'SELECT'::text, 'INSERT'::text, 'UPDATE'::text, 'DELETE'::text]))),
    CONSTRAINT policies_name_check CHECK ((length(name) >= 1))
);


ALTER TABLE engine_postgresql.policies OWNER TO sf_owner;

--
-- Name: TABLE policies; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.policies IS 'a row-security policy of a table.';


--
-- Name: COLUMN policies.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.id IS 'issued by the database';


--
-- Name: COLUMN policies.object; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.object IS 'the table';


--
-- Name: COLUMN policies.name; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.name IS 'its name';


--
-- Name: COLUMN policies.permissive; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.permissive IS 'false for RESTRICTIVE';


--
-- Name: COLUMN policies.command; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.command IS 'the commands it applies to';


--
-- Name: COLUMN policies.roles; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.roles IS 'the roles it applies to (["public"])';


--
-- Name: COLUMN policies.using_expression; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.using_expression IS 'the rows visible, in the engine''s SQL; NULL for none';


--
-- Name: COLUMN policies.check_expression; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.policies.check_expression IS 'the rows that may be written; NULL for none';


--
-- Name: policies_id_seq; Type: SEQUENCE; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE engine_postgresql.policies ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME engine_postgresql.policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: routines; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.routines (
    id bigint NOT NULL,
    volatility text DEFAULT 'volatile'::text NOT NULL,
    parallel text DEFAULT 'unsafe'::text NOT NULL,
    strict boolean DEFAULT false NOT NULL,
    leakproof boolean DEFAULT false NOT NULL,
    returns_set boolean DEFAULT false NOT NULL,
    cost numeric,
    result_rows numeric,
    config jsonb,
    owner text,
    acl jsonb,
    CONSTRAINT routines_parallel_check CHECK ((parallel = ANY (ARRAY['safe'::text, 'restricted'::text, 'unsafe'::text]))),
    CONSTRAINT routines_volatility_check CHECK ((volatility = ANY (ARRAY['immutable'::text, 'stable'::text, 'volatile'::text])))
);


ALTER TABLE engine_postgresql.routines OWNER TO sf_owner;

--
-- Name: TABLE routines; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.routines IS 'what PostgreSQL says of a function or procedure beyond the cortex.';


--
-- Name: COLUMN routines.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.id IS 'the routine';


--
-- Name: COLUMN routines.volatility; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.volatility IS 'what it promises about its results';


--
-- Name: COLUMN routines.parallel; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.parallel IS 'whether it may run in a parallel query';


--
-- Name: COLUMN routines.strict; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.strict IS 'true when it returns null on any null argument';


--
-- Name: COLUMN routines.leakproof; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.leakproof IS 'true when it reveals nothing of its arguments';


--
-- Name: COLUMN routines.returns_set; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.returns_set IS 'true when it returns rows';


--
-- Name: COLUMN routines.cost; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.cost IS 'its estimated cost; NULL for the default';


--
-- Name: COLUMN routines.result_rows; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.result_rows IS 'its estimated rows; NULL for the default';


--
-- Name: COLUMN routines.config; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.config IS 'settings it runs with (["search_path=features"]); NULL for none';


--
-- Name: COLUMN routines.owner; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.owner IS 'its owner, by role name; NULL for the one the schema is written as';


--
-- Name: COLUMN routines.acl; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.routines.acl IS 'its privileges; NULL for the defaults';


--
-- Name: rules; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.rules (
    id bigint NOT NULL,
    object bigint NOT NULL,
    name text NOT NULL,
    definition text NOT NULL,
    CONSTRAINT rules_name_check CHECK ((length(name) >= 1))
);


ALTER TABLE engine_postgresql.rules OWNER TO sf_owner;

--
-- Name: TABLE rules; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.rules IS 'a rewrite rule of a table, as the server writes it.';


--
-- Name: COLUMN rules.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.rules.id IS 'issued by the database';


--
-- Name: COLUMN rules.object; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.rules.object IS 'the table';


--
-- Name: COLUMN rules.name; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.rules.name IS 'its name';


--
-- Name: COLUMN rules.definition; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.rules.definition IS 'the rule as the server writes it (CREATE RULE ...)';


--
-- Name: rules_id_seq; Type: SEQUENCE; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE engine_postgresql.rules ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME engine_postgresql.rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sequences; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.sequences (
    id bigint NOT NULL,
    identity boolean DEFAULT false NOT NULL
);


ALTER TABLE engine_postgresql.sequences OWNER TO sf_owner;

--
-- Name: TABLE sequences; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.sequences IS 'what PostgreSQL says of a sequence beyond the cortex.';


--
-- Name: COLUMN sequences.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.sequences.id IS 'the sequence';


--
-- Name: COLUMN sequences.identity; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.sequences.identity IS 'true when an identity column made it, not CREATE SEQUENCE';


--
-- Name: triggers; Type: TABLE; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TABLE engine_postgresql.triggers (
    id bigint NOT NULL,
    function_name text NOT NULL,
    arguments jsonb,
    update_columns jsonb,
    old_table text,
    new_table text,
    enabled text DEFAULT 'origin'::text NOT NULL,
    CONSTRAINT triggers_enabled_check CHECK ((enabled = ANY (ARRAY['origin'::text, 'disabled'::text, 'replica'::text, 'always'::text])))
);


ALTER TABLE engine_postgresql.triggers OWNER TO sf_owner;

--
-- Name: TABLE triggers; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON TABLE engine_postgresql.triggers IS 'what PostgreSQL says of a trigger beyond the cortex.';


--
-- Name: COLUMN triggers.id; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.id IS 'the trigger';


--
-- Name: COLUMN triggers.function_name; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.function_name IS 'the trigger function, as the server names it (audit.log_change)';


--
-- Name: COLUMN triggers.arguments; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.arguments IS 'the arguments passed to it; NULL for none';


--
-- Name: COLUMN triggers.update_columns; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.update_columns IS 'UPDATE OF: the ids of the columns it fires on; NULL for any';


--
-- Name: COLUMN triggers.old_table; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.old_table IS 'the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none';


--
-- Name: COLUMN triggers.new_table; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.new_table IS 'the transition table of new rows; NULL for none';


--
-- Name: COLUMN triggers.enabled; Type: COMMENT; Schema: engine_postgresql; Owner: sf_owner
--

COMMENT ON COLUMN engine_postgresql.triggers.enabled IS 'when it fires';


--
-- Name: branches branches_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_name_key UNIQUE (name);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


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
-- Name: column_identities column_identities_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.column_identities
    ADD CONSTRAINT column_identities_pkey PRIMARY KEY (id);


--
-- Name: columns columns_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_pkey PRIMARY KEY (id);


--
-- Name: constraint_columns constraint_columns_constraint_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_constraint_position_key UNIQUE ("constraint", "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_pkey PRIMARY KEY (id);


--
-- Name: constraints constraints_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_pkey PRIMARY KEY (id);


--
-- Name: dependencies dependencies_object_uses_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_object_uses_key UNIQUE (object, uses) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_pkey PRIMARY KEY (id);


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
    ADD CONSTRAINT enum_values_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: enum_values enum_values_object_value_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_object_value_key UNIQUE (object, value) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: enum_values enum_values_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.enum_values
    ADD CONSTRAINT enum_values_pkey PRIMARY KEY (id);


--
-- Name: index_parts index_parts_index_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_index_position_key UNIQUE (index, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_pkey PRIMARY KEY (id);


--
-- Name: indexes indexes_object_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_object_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_pkey PRIMARY KEY (id);


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
-- Name: locked_versions locked_versions_turn_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_turn_key UNIQUE (turn);


--
-- Name: namespaces namespaces_parent_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_parent_name_key UNIQUE NULLS NOT DISTINCT (parent, name) DEFERRABLE INITIALLY DEFERRED;


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
-- Name: object_tags object_tags_object_tag_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_object_tag_key UNIQUE (object, tag) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: object_tags object_tags_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_pkey PRIMARY KEY (id);


--
-- Name: objects objects_namespace_kind_name_signature_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_kind_name_signature_key UNIQUE (namespace, kind, name, signature) DEFERRABLE INITIALLY DEFERRED;


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
-- Name: partitionings partitionings_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitionings
    ADD CONSTRAINT partitionings_pkey PRIMARY KEY (id);


--
-- Name: partitions partitions_partitioning_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_name_key UNIQUE (partitioning, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: partitions partitions_partitioning_position_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_position_key UNIQUE (partitioning, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: partitions partitions_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_pkey PRIMARY KEY (id);


--
-- Name: required_extensions required_extensions_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.required_extensions
    ADD CONSTRAINT required_extensions_name_key UNIQUE (name);


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
    ADD CONSTRAINT routine_parameters_routine_position_key UNIQUE (routine, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: routines routines_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routines
    ADD CONSTRAINT routines_pkey PRIMARY KEY (id);


--
-- Name: row_changes row_changes_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_pkey PRIMARY KEY (id);


--
-- Name: savepoints savepoints_name_key; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.savepoints
    ADD CONSTRAINT savepoints_name_key UNIQUE (name);


--
-- Name: savepoints savepoints_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.savepoints
    ADD CONSTRAINT savepoints_pkey PRIMARY KEY (id);


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
    ADD CONSTRAINT sort_fields_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


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
-- Name: views views_pkey; Type: CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.views
    ADD CONSTRAINT views_pkey PRIMARY KEY (id);


--
-- Name: collations collations_namespace_name_key; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.collations
    ADD CONSTRAINT collations_namespace_name_key UNIQUE (namespace, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: collations collations_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.collations
    ADD CONSTRAINT collations_pkey PRIMARY KEY (id);


--
-- Name: columns columns_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.columns
    ADD CONSTRAINT columns_pkey PRIMARY KEY (id);


--
-- Name: constraints constraints_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.constraints
    ADD CONSTRAINT constraints_pkey PRIMARY KEY (id);


--
-- Name: index_parts index_parts_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.index_parts
    ADD CONSTRAINT index_parts_pkey PRIMARY KEY (id);


--
-- Name: indexes indexes_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.indexes
    ADD CONSTRAINT indexes_pkey PRIMARY KEY (id);


--
-- Name: inheritance inheritance_object_position_key; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.inheritance
    ADD CONSTRAINT inheritance_object_position_key UNIQUE (object, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: inheritance inheritance_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.inheritance
    ADD CONSTRAINT inheritance_pkey PRIMARY KEY (id);


--
-- Name: namespaces namespaces_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.namespaces
    ADD CONSTRAINT namespaces_pkey PRIMARY KEY (id);


--
-- Name: policies policies_object_name_key; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.policies
    ADD CONSTRAINT policies_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: policies policies_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.policies
    ADD CONSTRAINT policies_pkey PRIMARY KEY (id);


--
-- Name: relations relations_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.relations
    ADD CONSTRAINT relations_pkey PRIMARY KEY (id);


--
-- Name: routines routines_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.routines
    ADD CONSTRAINT routines_pkey PRIMARY KEY (id);


--
-- Name: rules rules_object_name_key; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.rules
    ADD CONSTRAINT rules_object_name_key UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rules rules_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.rules
    ADD CONSTRAINT rules_pkey PRIMARY KEY (id);


--
-- Name: sequences sequences_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.sequences
    ADD CONSTRAINT sequences_pkey PRIMARY KEY (id);


--
-- Name: triggers triggers_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.triggers
    ADD CONSTRAINT triggers_pkey PRIMARY KEY (id);


--
-- Name: types types_pkey; Type: CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.types
    ADD CONSTRAINT types_pkey PRIMARY KEY (id);


--
-- Name: row_changes_operation; Type: INDEX; Schema: cortex; Owner: sf_owner
--

CREATE INDEX row_changes_operation ON cortex.row_changes USING btree (operation, id);


--
-- Name: branches rule:cortex.branch_heads_are_turns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.branch_heads_are_turns" AFTER INSERT OR DELETE OR UPDATE ON cortex.branches DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_branch_heads_are_turns');


--
-- Name: turns rule:cortex.branch_heads_are_turns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.branch_heads_are_turns" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_branch_heads_are_turns');


--
-- Name: branches rule:cortex.branch_heads_are_turns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.branch_heads_are_turns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.branches FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_branch_heads_are_turns');


--
-- Name: turns rule:cortex.branch_heads_are_turns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.branch_heads_are_turns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_branch_heads_are_turns');


--
-- Name: columns rule:cortex.constraint_columns_on_their_tables; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.constraint_columns_on_their_tables" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_constraint_columns_on_their_tables');


--
-- Name: constraint_columns rule:cortex.constraint_columns_on_their_tables; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.constraint_columns_on_their_tables" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_constraint_columns_on_their_tables');


--
-- Name: constraints rule:cortex.constraint_columns_on_their_tables; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.constraint_columns_on_their_tables" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_constraint_columns_on_their_tables');


--
-- Name: columns rule:cortex.constraint_columns_on_their_tables:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.constraint_columns_on_their_tables:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_constraint_columns_on_their_tables');


--
-- Name: constraint_columns rule:cortex.constraint_columns_on_their_tables:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.constraint_columns_on_their_tables:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_constraint_columns_on_their_tables');


--
-- Name: constraints rule:cortex.constraint_columns_on_their_tables:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.constraint_columns_on_their_tables:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_constraint_columns_on_their_tables');


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
-- Name: columns rule:cortex.index_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.index_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_index_columns_on_their_table');


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
-- Name: index_parts rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.index_parts FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: indexes rule:cortex.index_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.index_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.indexes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_index_columns_on_their_table');


--
-- Name: constraint_columns rule:cortex.links_have_columns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.links_have_columns" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_links_have_columns');


--
-- Name: constraints rule:cortex.links_have_columns; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.links_have_columns" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_links_have_columns');


--
-- Name: constraint_columns rule:cortex.links_have_columns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.links_have_columns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_links_have_columns');


--
-- Name: constraints rule:cortex.links_have_columns:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.links_have_columns:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_links_have_columns');


--
-- Name: branches rule:cortex.one_current_branch; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.one_current_branch" AFTER INSERT OR DELETE OR UPDATE ON cortex.branches DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_one_current_branch');


--
-- Name: branches rule:cortex.one_current_branch:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.one_current_branch:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.branches FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_one_current_branch');


--
-- Name: operations rule:cortex.operation_after_its_turn; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.operation_after_its_turn" AFTER INSERT OR DELETE OR UPDATE ON cortex.operations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_operation_after_its_turn');


--
-- Name: turns rule:cortex.operation_after_its_turn; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.operation_after_its_turn" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_operation_after_its_turn');


--
-- Name: operations rule:cortex.operation_after_its_turn:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.operation_after_its_turn:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.operations FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_operation_after_its_turn');


--
-- Name: turns rule:cortex.operation_after_its_turn:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.operation_after_its_turn:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_operation_after_its_turn');


--
-- Name: domains rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: objects rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: partitionings rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitionings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: routines rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: sequences rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: triggers rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: views rule:cortex.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.views DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_parts_of_their_kind');


--
-- Name: domains rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.domains FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: objects rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: partitionings rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.partitionings FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: routines rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.routines FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: sequences rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sequences FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: triggers rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.triggers FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: views rule:cortex.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.views FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_parts_of_their_kind');


--
-- Name: columns rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: constraint_columns rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: constraints rule:cortex.primary_key_columns_not_null; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.primary_key_columns_not_null" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_primary_key_columns_not_null');


--
-- Name: columns rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: constraint_columns rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraint_columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: constraints rule:cortex.primary_key_columns_not_null:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.primary_key_columns_not_null:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.constraints FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_primary_key_columns_not_null');


--
-- Name: row_changes rule:cortex.row_changes_name_tables_of_the_database; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.row_changes_name_tables_of_the_database" AFTER INSERT OR DELETE OR UPDATE ON cortex.row_changes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_row_changes_name_tables_of_the_database');


--
-- Name: row_changes rule:cortex.row_changes_name_tables_of_the_database:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.row_changes_name_tables_of_the_database:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.row_changes FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_row_changes_name_tables_of_the_database');


--
-- Name: columns rule:cortex.sort_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.sort_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_sort_columns_on_their_table');


--
-- Name: sort_fields rule:cortex.sort_columns_on_their_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.sort_columns_on_their_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_sort_columns_on_their_table');


--
-- Name: columns rule:cortex.sort_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.sort_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.columns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_sort_columns_on_their_table');


--
-- Name: sort_fields rule:cortex.sort_columns_on_their_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.sort_columns_on_their_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.sort_fields FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_sort_columns_on_their_table');


--
-- Name: objects rule:cortex.triggers_on_a_table; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.triggers_on_a_table" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_triggers_on_a_table');


--
-- Name: objects rule:cortex.triggers_on_a_table:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.triggers_on_a_table:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_triggers_on_a_table');


--
-- Name: turns rule:cortex.turn_takes_back_an_earlier_turn; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.turn_takes_back_an_earlier_turn" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_turn_takes_back_an_earlier_turn');


--
-- Name: turns rule:cortex.turn_takes_back_an_earlier_turn:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.turn_takes_back_an_earlier_turn:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_turn_takes_back_an_earlier_turn');


--
-- Name: turns rule:cortex.turns_follow_their_parent; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.turns_follow_their_parent" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_turns_follow_their_parent');


--
-- Name: turns rule:cortex.turns_follow_their_parent:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.turns_follow_their_parent:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.turns FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_turns_follow_their_parent');


--
-- Name: locked_versions rule:cortex.versions_follow_the_log; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:cortex.versions_follow_the_log" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('cortex.broken_versions_follow_the_log');


--
-- Name: locked_versions rule:cortex.versions_follow_the_log:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:cortex.versions_follow_the_log:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.locked_versions FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('cortex.broken_versions_follow_the_log');


--
-- Name: objects rule:engine_postgresql.parts_of_their_kind; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_postgresql.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: objects rule:engine_postgresql.parts_of_their_kind:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_postgresql.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: objects rule:engine_postgresql.relations_have_their_facts; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_postgresql.relations_have_their_facts" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_postgresql.broken_relations_have_their_facts');


--
-- Name: objects rule:engine_postgresql.relations_have_their_facts:again; Type: TRIGGER; Schema: cortex; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_postgresql.relations_have_their_facts:again" AFTER INSERT OR DELETE OR UPDATE ON cortex.objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_postgresql.broken_relations_have_their_facts');


--
-- Name: relations rule:engine_postgresql.parts_of_their_kind; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_postgresql.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.relations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: types rule:engine_postgresql.parts_of_their_kind; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_postgresql.parts_of_their_kind" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.types DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: relations rule:engine_postgresql.parts_of_their_kind:again; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_postgresql.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.relations FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: types rule:engine_postgresql.parts_of_their_kind:again; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_postgresql.parts_of_their_kind:again" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.types FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_postgresql.broken_parts_of_their_kind');


--
-- Name: relations rule:engine_postgresql.relations_have_their_facts; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE CONSTRAINT TRIGGER "rule:engine_postgresql.relations_have_their_facts" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.relations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION cortex.rule_check('engine_postgresql.broken_relations_have_their_facts');


--
-- Name: relations rule:engine_postgresql.relations_have_their_facts:again; Type: TRIGGER; Schema: engine_postgresql; Owner: sf_owner
--

CREATE TRIGGER "rule:engine_postgresql.relations_have_their_facts:again" AFTER INSERT OR DELETE OR UPDATE ON engine_postgresql.relations FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again('engine_postgresql.broken_relations_have_their_facts');


--
-- Name: catalog_sources catalog_sources_version_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.catalog_sources
    ADD CONSTRAINT catalog_sources_version_fkey FOREIGN KEY (version) REFERENCES cortex.engine_versions(id);


--
-- Name: column_identities column_identities_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.column_identities
    ADD CONSTRAINT column_identities_id_fkey FOREIGN KEY (id) REFERENCES cortex.columns(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: column_identities column_identities_sequence_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.column_identities
    ADD CONSTRAINT column_identities_sequence_fkey FOREIGN KEY (sequence) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.columns
    ADD CONSTRAINT columns_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_constraint_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_constraint_fkey FOREIGN KEY ("constraint") REFERENCES cortex.constraints(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraint_columns constraint_columns_to_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraint_columns
    ADD CONSTRAINT constraint_columns_to_column_fkey FOREIGN KEY (to_column) REFERENCES cortex.columns(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_index_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_index_fkey FOREIGN KEY (index) REFERENCES cortex.indexes(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_to_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.constraints
    ADD CONSTRAINT constraints_to_object_fkey FOREIGN KEY (to_object) REFERENCES cortex.objects(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: dependencies dependencies_uses_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.dependencies
    ADD CONSTRAINT dependencies_uses_fkey FOREIGN KEY (uses) REFERENCES cortex.objects(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: domains domains_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.domains
    ADD CONSTRAINT domains_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


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
    ADD CONSTRAINT enum_values_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_index_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.index_parts
    ADD CONSTRAINT index_parts_index_fkey FOREIGN KEY (index) REFERENCES cortex.indexes(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.indexes
    ADD CONSTRAINT indexes_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: locked_versions locked_versions_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.locked_versions
    ADD CONSTRAINT locked_versions_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: namespaces namespaces_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.namespaces
    ADD CONSTRAINT namespaces_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.namespaces(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: object_tags object_tags_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.object_tags
    ADD CONSTRAINT object_tags_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_kind_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_kind_fkey FOREIGN KEY (kind) REFERENCES cortex.object_kinds(id);


--
-- Name: objects objects_namespace_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_namespace_fkey FOREIGN KEY (namespace) REFERENCES cortex.namespaces(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: objects objects_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.objects
    ADD CONSTRAINT objects_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: operations operations_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.operations
    ADD CONSTRAINT operations_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: partitionings partitionings_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitionings
    ADD CONSTRAINT partitionings_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: partitions partitions_partitioning_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_partitioning_fkey FOREIGN KEY (partitioning) REFERENCES cortex.partitionings(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: partitions partitions_table_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.partitions
    ADD CONSTRAINT partitions_table_object_fkey FOREIGN KEY (table_object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: routine_parameters routine_parameters_routine_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routine_parameters
    ADD CONSTRAINT routine_parameters_routine_fkey FOREIGN KEY (routine) REFERENCES cortex.routines(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: routines routines_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.routines
    ADD CONSTRAINT routines_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: row_changes row_changes_operation_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.row_changes
    ADD CONSTRAINT row_changes_operation_fkey FOREIGN KEY (operation) REFERENCES cortex.operations(id);


--
-- Name: savepoints savepoints_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.savepoints
    ADD CONSTRAINT savepoints_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: sequences sequences_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sequences
    ADD CONSTRAINT sequences_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: sequences sequences_owned_by_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sequences
    ADD CONSTRAINT sequences_owned_by_fkey FOREIGN KEY (owned_by) REFERENCES cortex.columns(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: sort_fields sort_fields_column_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_column_fkey FOREIGN KEY ("column") REFERENCES cortex.columns(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: sort_fields sort_fields_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.sort_fields
    ADD CONSTRAINT sort_fields_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: source_reads source_reads_turn_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.source_reads
    ADD CONSTRAINT source_reads_turn_fkey FOREIGN KEY (turn) REFERENCES cortex.turns(id);


--
-- Name: triggers triggers_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.triggers
    ADD CONSTRAINT triggers_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: turns turns_branch_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_branch_fkey FOREIGN KEY (branch) REFERENCES cortex.branches(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: turns turns_parent_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.turns(id);


--
-- Name: turns turns_undoes_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.turns
    ADD CONSTRAINT turns_undoes_fkey FOREIGN KEY (undoes) REFERENCES cortex.turns(id);


--
-- Name: verbatim_statements verbatim_statements_after_namespace_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_after_namespace_fkey FOREIGN KEY (after_namespace) REFERENCES cortex.namespaces(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: verbatim_statements verbatim_statements_after_object_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.verbatim_statements
    ADD CONSTRAINT verbatim_statements_after_object_fkey FOREIGN KEY (after_object) REFERENCES cortex.objects(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: views views_id_fkey; Type: FK CONSTRAINT; Schema: cortex; Owner: sf_owner
--

ALTER TABLE ONLY cortex.views
    ADD CONSTRAINT views_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: collations collations_namespace_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.collations
    ADD CONSTRAINT collations_namespace_fkey FOREIGN KEY (namespace) REFERENCES cortex.namespaces(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: columns columns_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.columns
    ADD CONSTRAINT columns_id_fkey FOREIGN KEY (id) REFERENCES cortex.columns(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: constraints constraints_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.constraints
    ADD CONSTRAINT constraints_id_fkey FOREIGN KEY (id) REFERENCES cortex.constraints(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: index_parts index_parts_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.index_parts
    ADD CONSTRAINT index_parts_id_fkey FOREIGN KEY (id) REFERENCES cortex.index_parts(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.indexes
    ADD CONSTRAINT indexes_id_fkey FOREIGN KEY (id) REFERENCES cortex.indexes(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: indexes indexes_parent_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.indexes
    ADD CONSTRAINT indexes_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.indexes(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: inheritance inheritance_object_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.inheritance
    ADD CONSTRAINT inheritance_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: inheritance inheritance_parent_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.inheritance
    ADD CONSTRAINT inheritance_parent_fkey FOREIGN KEY (parent) REFERENCES cortex.objects(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: namespaces namespaces_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.namespaces
    ADD CONSTRAINT namespaces_id_fkey FOREIGN KEY (id) REFERENCES cortex.namespaces(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: policies policies_object_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.policies
    ADD CONSTRAINT policies_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: relations relations_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.relations
    ADD CONSTRAINT relations_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: routines routines_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.routines
    ADD CONSTRAINT routines_id_fkey FOREIGN KEY (id) REFERENCES cortex.routines(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rules rules_object_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.rules
    ADD CONSTRAINT rules_object_fkey FOREIGN KEY (object) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: sequences sequences_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.sequences
    ADD CONSTRAINT sequences_id_fkey FOREIGN KEY (id) REFERENCES cortex.sequences(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: triggers triggers_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.triggers
    ADD CONSTRAINT triggers_id_fkey FOREIGN KEY (id) REFERENCES cortex.triggers(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: types types_id_fkey; Type: FK CONSTRAINT; Schema: engine_postgresql; Owner: sf_owner
--

ALTER TABLE ONLY engine_postgresql.types
    ADD CONSTRAINT types_id_fkey FOREIGN KEY (id) REFERENCES cortex.objects(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: SCHEMA cortex; Type: ACL; Schema: -; Owner: sf_owner
--

GRANT USAGE ON SCHEMA cortex TO sf_service;
GRANT USAGE ON SCHEMA cortex TO sf_agent;
GRANT USAGE ON SCHEMA cortex TO sf_reader;


--
-- Name: SCHEMA engine_postgresql; Type: ACL; Schema: -; Owner: sf_owner
--

GRANT USAGE ON SCHEMA engine_postgresql TO sf_service;
GRANT USAGE ON SCHEMA engine_postgresql TO sf_agent;
GRANT USAGE ON SCHEMA engine_postgresql TO sf_reader;


--
-- Name: FUNCTION enforce_rules(owner text); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.enforce_rules(owner text) TO sf_service;
GRANT ALL ON FUNCTION cortex.enforce_rules(owner text) TO sf_agent;


--
-- Name: FUNCTION grant_roles(owner text); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.grant_roles(owner text) TO sf_service;
GRANT ALL ON FUNCTION cortex.grant_roles(owner text) TO sf_agent;


--
-- Name: FUNCTION rule_again(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_again() TO sf_service;
GRANT ALL ON FUNCTION cortex.rule_again() TO sf_agent;


--
-- Name: FUNCTION rule_check(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_check() TO sf_service;
GRANT ALL ON FUNCTION cortex.rule_check() TO sf_agent;


--
-- Name: FUNCTION rule_marks(); Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT ALL ON FUNCTION cortex.rule_marks() TO sf_service;
GRANT ALL ON FUNCTION cortex.rule_marks() TO sf_agent;


--
-- Name: TABLE branches; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.branches TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.branches TO sf_agent;
GRANT SELECT ON TABLE cortex.branches TO sf_reader;


--
-- Name: TABLE turns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.turns TO sf_service;
GRANT SELECT,INSERT ON TABLE cortex.turns TO sf_agent;
GRANT SELECT ON TABLE cortex.turns TO sf_reader;


--
-- Name: TABLE broken_branch_heads_are_turns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_branch_heads_are_turns TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_branch_heads_are_turns TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_branch_heads_are_turns TO sf_reader;


--
-- Name: TABLE columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.columns TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.columns TO sf_agent;
GRANT SELECT ON TABLE cortex.columns TO sf_reader;


--
-- Name: TABLE constraint_columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraint_columns TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraint_columns TO sf_agent;
GRANT SELECT ON TABLE cortex.constraint_columns TO sf_reader;


--
-- Name: TABLE constraints; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraints TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.constraints TO sf_agent;
GRANT SELECT ON TABLE cortex.constraints TO sf_reader;


--
-- Name: TABLE broken_constraint_columns_on_their_tables; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_constraint_columns_on_their_tables TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_constraint_columns_on_their_tables TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_constraint_columns_on_their_tables TO sf_reader;


--
-- Name: TABLE engine_features; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.engine_features TO sf_service;
GRANT SELECT ON TABLE cortex.engine_features TO sf_agent;
GRANT SELECT ON TABLE cortex.engine_features TO sf_reader;


--
-- Name: TABLE engine_versions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.engine_versions TO sf_service;
GRANT SELECT ON TABLE cortex.engine_versions TO sf_agent;
GRANT SELECT ON TABLE cortex.engine_versions TO sf_reader;


--
-- Name: TABLE broken_features_since_before_until; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_features_since_before_until TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_features_since_before_until TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_features_since_before_until TO sf_reader;


--
-- Name: TABLE index_parts; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_parts TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.index_parts TO sf_agent;
GRANT SELECT ON TABLE cortex.index_parts TO sf_reader;


--
-- Name: TABLE indexes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.indexes TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.indexes TO sf_agent;
GRANT SELECT ON TABLE cortex.indexes TO sf_reader;


--
-- Name: TABLE broken_index_columns_on_their_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_index_columns_on_their_table TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_index_columns_on_their_table TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_index_columns_on_their_table TO sf_reader;


--
-- Name: TABLE broken_links_have_columns; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_links_have_columns TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_links_have_columns TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_links_have_columns TO sf_reader;


--
-- Name: TABLE broken_one_current_branch; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_one_current_branch TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_one_current_branch TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_one_current_branch TO sf_reader;


--
-- Name: TABLE operations; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.operations TO sf_service;
GRANT SELECT,INSERT ON TABLE cortex.operations TO sf_agent;
GRANT SELECT ON TABLE cortex.operations TO sf_reader;


--
-- Name: TABLE broken_operation_after_its_turn; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_operation_after_its_turn TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_operation_after_its_turn TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_operation_after_its_turn TO sf_reader;


--
-- Name: TABLE domains; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.domains TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.domains TO sf_agent;
GRANT SELECT ON TABLE cortex.domains TO sf_reader;


--
-- Name: TABLE objects; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.objects TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.objects TO sf_agent;
GRANT SELECT ON TABLE cortex.objects TO sf_reader;


--
-- Name: TABLE partitionings; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partitionings TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partitionings TO sf_agent;
GRANT SELECT ON TABLE cortex.partitionings TO sf_reader;


--
-- Name: TABLE routines; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routines TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routines TO sf_agent;
GRANT SELECT ON TABLE cortex.routines TO sf_reader;


--
-- Name: TABLE sequences; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sequences TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sequences TO sf_agent;
GRANT SELECT ON TABLE cortex.sequences TO sf_reader;


--
-- Name: TABLE triggers; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.triggers TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.triggers TO sf_agent;
GRANT SELECT ON TABLE cortex.triggers TO sf_reader;


--
-- Name: TABLE views; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.views TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.views TO sf_agent;
GRANT SELECT ON TABLE cortex.views TO sf_reader;


--
-- Name: TABLE broken_parts_of_their_kind; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_parts_of_their_kind TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_parts_of_their_kind TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_parts_of_their_kind TO sf_reader;


--
-- Name: TABLE broken_primary_key_columns_not_null; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_primary_key_columns_not_null TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_primary_key_columns_not_null TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_primary_key_columns_not_null TO sf_reader;


--
-- Name: TABLE row_changes; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.row_changes TO sf_service;
GRANT SELECT,INSERT ON TABLE cortex.row_changes TO sf_agent;
GRANT SELECT ON TABLE cortex.row_changes TO sf_reader;


--
-- Name: TABLE broken_row_changes_name_tables_of_the_database; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_row_changes_name_tables_of_the_database TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_row_changes_name_tables_of_the_database TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_row_changes_name_tables_of_the_database TO sf_reader;


--
-- Name: TABLE sort_fields; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sort_fields TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.sort_fields TO sf_agent;
GRANT SELECT ON TABLE cortex.sort_fields TO sf_reader;


--
-- Name: TABLE broken_sort_columns_on_their_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_sort_columns_on_their_table TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_sort_columns_on_their_table TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_sort_columns_on_their_table TO sf_reader;


--
-- Name: TABLE broken_triggers_on_a_table; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_triggers_on_a_table TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_triggers_on_a_table TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_triggers_on_a_table TO sf_reader;


--
-- Name: TABLE broken_turn_takes_back_an_earlier_turn; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_turn_takes_back_an_earlier_turn TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_turn_takes_back_an_earlier_turn TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_turn_takes_back_an_earlier_turn TO sf_reader;


--
-- Name: TABLE broken_turns_follow_their_parent; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_turns_follow_their_parent TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_turns_follow_their_parent TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_turns_follow_their_parent TO sf_reader;


--
-- Name: TABLE locked_versions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.locked_versions TO sf_service;
GRANT SELECT ON TABLE cortex.locked_versions TO sf_agent;
GRANT SELECT ON TABLE cortex.locked_versions TO sf_reader;


--
-- Name: TABLE broken_versions_follow_the_log; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_versions_follow_the_log TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.broken_versions_follow_the_log TO sf_agent;
GRANT SELECT ON TABLE cortex.broken_versions_follow_the_log TO sf_reader;


--
-- Name: TABLE catalog_sources; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.catalog_sources TO sf_service;
GRANT SELECT ON TABLE cortex.catalog_sources TO sf_agent;
GRANT SELECT ON TABLE cortex.catalog_sources TO sf_reader;


--
-- Name: TABLE column_identities; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.column_identities TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.column_identities TO sf_agent;
GRANT SELECT ON TABLE cortex.column_identities TO sf_reader;


--
-- Name: TABLE dependencies; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.dependencies TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.dependencies TO sf_agent;
GRANT SELECT ON TABLE cortex.dependencies TO sf_reader;


--
-- Name: TABLE enum_values; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.enum_values TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.enum_values TO sf_agent;
GRANT SELECT ON TABLE cortex.enum_values TO sf_reader;


--
-- Name: TABLE namespaces; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.namespaces TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.namespaces TO sf_agent;
GRANT SELECT ON TABLE cortex.namespaces TO sf_reader;


--
-- Name: TABLE object_kinds; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_kinds TO sf_service;
GRANT SELECT ON TABLE cortex.object_kinds TO sf_agent;
GRANT SELECT ON TABLE cortex.object_kinds TO sf_reader;


--
-- Name: TABLE object_tags; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_tags TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.object_tags TO sf_agent;
GRANT SELECT ON TABLE cortex.object_tags TO sf_reader;


--
-- Name: TABLE partitions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partitions TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.partitions TO sf_agent;
GRANT SELECT ON TABLE cortex.partitions TO sf_reader;


--
-- Name: TABLE required_extensions; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.required_extensions TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.required_extensions TO sf_agent;
GRANT SELECT ON TABLE cortex.required_extensions TO sf_reader;


--
-- Name: TABLE routine_parameters; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routine_parameters TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.routine_parameters TO sf_agent;
GRANT SELECT ON TABLE cortex.routine_parameters TO sf_reader;


--
-- Name: TABLE savepoints; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.savepoints TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.savepoints TO sf_agent;
GRANT SELECT ON TABLE cortex.savepoints TO sf_reader;


--
-- Name: TABLE schema_identity; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.schema_identity TO sf_service;
GRANT SELECT ON TABLE cortex.schema_identity TO sf_agent;
GRANT SELECT ON TABLE cortex.schema_identity TO sf_reader;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.schema_migrations TO sf_service;
GRANT SELECT ON TABLE cortex.schema_migrations TO sf_agent;
GRANT SELECT ON TABLE cortex.schema_migrations TO sf_reader;


--
-- Name: TABLE source_reads; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.source_reads TO sf_service;
GRANT SELECT ON TABLE cortex.source_reads TO sf_agent;
GRANT SELECT ON TABLE cortex.source_reads TO sf_reader;


--
-- Name: TABLE verbatim_statements; Type: ACL; Schema: cortex; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.verbatim_statements TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE cortex.verbatim_statements TO sf_agent;
GRANT SELECT ON TABLE cortex.verbatim_statements TO sf_reader;


--
-- Name: TABLE relations; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.relations TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.relations TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.relations TO sf_reader;


--
-- Name: TABLE types; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.types TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.types TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.types TO sf_reader;


--
-- Name: TABLE broken_parts_of_their_kind; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.broken_parts_of_their_kind TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.broken_parts_of_their_kind TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.broken_parts_of_their_kind TO sf_reader;


--
-- Name: TABLE broken_relations_have_their_facts; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.broken_relations_have_their_facts TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.broken_relations_have_their_facts TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.broken_relations_have_their_facts TO sf_reader;


--
-- Name: TABLE collations; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.collations TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.collations TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.collations TO sf_reader;


--
-- Name: TABLE columns; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.columns TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.columns TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.columns TO sf_reader;


--
-- Name: TABLE constraints; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.constraints TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.constraints TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.constraints TO sf_reader;


--
-- Name: TABLE index_parts; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.index_parts TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.index_parts TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.index_parts TO sf_reader;


--
-- Name: TABLE indexes; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.indexes TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.indexes TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.indexes TO sf_reader;


--
-- Name: TABLE inheritance; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.inheritance TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.inheritance TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.inheritance TO sf_reader;


--
-- Name: TABLE namespaces; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.namespaces TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.namespaces TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.namespaces TO sf_reader;


--
-- Name: TABLE policies; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.policies TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.policies TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.policies TO sf_reader;


--
-- Name: TABLE routines; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.routines TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.routines TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.routines TO sf_reader;


--
-- Name: TABLE rules; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.rules TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.rules TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.rules TO sf_reader;


--
-- Name: TABLE sequences; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.sequences TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.sequences TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.sequences TO sf_reader;


--
-- Name: TABLE triggers; Type: ACL; Schema: engine_postgresql; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.triggers TO sf_service;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engine_postgresql.triggers TO sf_agent;
GRANT SELECT ON TABLE engine_postgresql.triggers TO sf_reader;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: cortex; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT ALL ON FUNCTIONS TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT ALL ON FUNCTIONS TO sf_agent;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: cortex; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_agent;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA cortex GRANT SELECT ON TABLES TO sf_reader;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: engine_postgresql; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_postgresql GRANT ALL ON FUNCTIONS TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_postgresql GRANT ALL ON FUNCTIONS TO sf_agent;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: engine_postgresql; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_postgresql GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_postgresql GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_agent;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA engine_postgresql GRANT SELECT ON TABLES TO sf_reader;


--
-- PostgreSQL database dump complete
--
