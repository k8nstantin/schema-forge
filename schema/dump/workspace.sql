-- schema/dump/workspace.sql: the schema-only pg_dump of the database workspace make, as the locked design gives it.
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
-- Name: workspace; Type: SCHEMA; Schema: -; Owner: sf_owner
--

CREATE SCHEMA workspace;


ALTER SCHEMA workspace OWNER TO sf_owner;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: connection_test_steps; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.connection_test_steps (
    id text NOT NULL,
    test uuid NOT NULL,
    step text NOT NULL,
    outcome text NOT NULL,
    said text NOT NULL,
    CONSTRAINT connection_test_steps_check CHECK ((id = ((test || '.'::text) || step))),
    CONSTRAINT connection_test_steps_outcome_check CHECK ((outcome = ANY (ARRAY['passed'::text, 'warning'::text, 'failed'::text, 'skipped'::text]))),
    CONSTRAINT connection_test_steps_step_check CHECK ((step = ANY (ARRAY['reach'::text, 'secure'::text, 'sign_in'::text, 'version'::text, 'rights'::text])))
);


ALTER TABLE workspace.connection_test_steps OWNER TO sf_owner;

--
-- Name: TABLE connection_test_steps; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.connection_test_steps IS 'each step of a connection test, in order, and what it said (docs/connections.xml).';


--
-- Name: COLUMN connection_test_steps.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_test_steps.id IS '<test>.<step>';


--
-- Name: COLUMN connection_test_steps.test; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_test_steps.test IS 'the test';


--
-- Name: COLUMN connection_test_steps.step; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_test_steps.step IS 'the step';


--
-- Name: COLUMN connection_test_steps.outcome; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_test_steps.outcome IS 'how it went';


--
-- Name: COLUMN connection_test_steps.said; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_test_steps.said IS 'what happened, in the engine''s sentence; never a secret';


--
-- Name: connection_tests; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.connection_tests (
    id uuid DEFAULT uuidv7() NOT NULL,
    connection uuid NOT NULL,
    outcome text NOT NULL,
    tested_at timestamp with time zone NOT NULL,
    CONSTRAINT connection_tests_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT connection_tests_outcome_check CHECK ((outcome = ANY (ARRAY['passed'::text, 'warning'::text, 'failed'::text])))
);


ALTER TABLE workspace.connection_tests OWNER TO sf_owner;

--
-- Name: TABLE connection_tests; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.connection_tests IS 'each test of a saved connection, and how it went.';


--
-- Name: COLUMN connection_tests.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_tests.id IS 'UUIDv7, issued when the test ran';


--
-- Name: COLUMN connection_tests.connection; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_tests.connection IS 'the connection tested';


--
-- Name: COLUMN connection_tests.outcome; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_tests.outcome IS 'passed, passed with a warning, or failed';


--
-- Name: COLUMN connection_tests.tested_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_tests.tested_at IS 'when';


--
-- Name: connection_values; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.connection_values (
    id text NOT NULL,
    connection uuid NOT NULL,
    field text NOT NULL,
    value text NOT NULL,
    CONSTRAINT connection_values_check CHECK ((id = ((connection || '.'::text) || field))),
    CONSTRAINT connection_values_field_check CHECK ((length(field) >= 1)),
    CONSTRAINT connection_values_value_check CHECK ((length(value) >= 1))
);


ALTER TABLE workspace.connection_values OWNER TO sf_owner;

--
-- Name: TABLE connection_values; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.connection_values IS 'the value of each field a connection''s engine declares, by the field''s key; never a field the engine declares secret.';


--
-- Name: COLUMN connection_values.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_values.id IS '<connection>.<field key>';


--
-- Name: COLUMN connection_values.connection; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_values.connection IS 'the connection';


--
-- Name: COLUMN connection_values.field; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_values.field IS 'the key of a field the engine declares, as the engine gives it';


--
-- Name: COLUMN connection_values.value; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connection_values.value IS 'its value; a field left empty has no row, and the engine''s default applies';


--
-- Name: connections; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.connections (
    id uuid DEFAULT uuidv7() NOT NULL,
    name text NOT NULL,
    engine text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT connections_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT connections_name_check CHECK ((((length(name) >= 1) AND (length(name) <= 100)) AND (name ~ '^[A-Za-z0-9-][A-Za-z0-9_.-]*$'::text)))
);


ALTER TABLE workspace.connections OWNER TO sf_owner;

--
-- Name: TABLE connections; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.connections IS 'a saved connection to a live database: a name and an engine; its values are in connection_values, never its secret (docs/connections.xml).';


--
-- Name: COLUMN connections.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connections.id IS 'UUIDv7';


--
-- Name: COLUMN connections.name; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connections.name IS 'as people call it (prod-replica)';


--
-- Name: COLUMN connections.engine; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connections.engine IS 'the id of the engine whose fields it fills';


--
-- Name: COLUMN connections.created_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.connections.created_at IS 'when';


--
-- Name: parameters; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.parameters (
    id text NOT NULL,
    value jsonb NOT NULL,
    about text NOT NULL,
    changed_at timestamp with time zone,
    changed_by text,
    CONSTRAINT parameters_about_check CHECK ((length(about) >= 1)),
    CONSTRAINT parameters_check CHECK (((changed_at IS NULL) = (changed_by IS NULL))),
    CONSTRAINT parameters_id_check CHECK ((id ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text))
);


ALTER TABLE workspace.parameters OWNER TO sf_owner;

--
-- Name: TABLE parameters; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.parameters IS 'every value a person may want changed without a new build: the product''s name, labels, limits and defaults. Nothing a person may want changed is written in code (decision parameters-not-code); code reads it here. A version ships its parameters as seeds (schema/workspace/seeds/), inserted only where the key is missing, so a value someone changed is kept.';


--
-- Name: COLUMN parameters.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.parameters.id IS 'the key, dotted by what it belongs to: product.name';


--
-- Name: COLUMN parameters.value; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.parameters.value IS 'its value: a string, a number, true or false, a list or an object';


--
-- Name: COLUMN parameters.about; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.parameters.about IS 'what it is and where it shows, for the person who changes it';


--
-- Name: COLUMN parameters.changed_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.parameters.changed_at IS 'when a person last changed it; NULL while it holds the value its seed gave';


--
-- Name: COLUMN parameters.changed_by; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.parameters.changed_by IS 'who changed it; NULL while it holds the value its seed gave';


--
-- Name: schema_connections; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.schema_connections (
    id uuid DEFAULT uuidv7() NOT NULL,
    schema_id uuid NOT NULL,
    connection_id uuid NOT NULL,
    database_name text NOT NULL,
    scope jsonb DEFAULT '{"everything": true}'::jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT schema_connections_database_name_check CHECK ((length(database_name) >= 1)),
    CONSTRAINT schema_connections_id_check CHECK ((uuid_extract_version(id) = 7))
);


ALTER TABLE workspace.schema_connections OWNER TO sf_owner;

--
-- Name: TABLE schema_connections; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.schema_connections IS 'the saved connection a schema is read from, and which database on it.';


--
-- Name: COLUMN schema_connections.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.id IS 'UUIDv7';


--
-- Name: COLUMN schema_connections.schema_id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.schema_id IS 'the schema, by its id';


--
-- Name: COLUMN schema_connections.connection_id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.connection_id IS 'the saved connection it is read from';


--
-- Name: COLUMN schema_connections.database_name; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.database_name IS 'the database on that server it is read from, as the server names it (shop)';


--
-- Name: COLUMN schema_connections.scope; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.scope IS 'what is read from it each time (decision read-scope): everything unless the person chose otherwise; a later read asks the same';


--
-- Name: COLUMN schema_connections.created_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_connections.created_at IS 'when the schema was tied to it';


--
-- Name: schema_migrations; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.schema_migrations (
    id text NOT NULL,
    owner text NOT NULL,
    version integer NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone NOT NULL,
    CONSTRAINT schema_migrations_check CHECK ((id = ((owner || '/'::text) || version))),
    CONSTRAINT schema_migrations_checksum_check CHECK ((length(checksum) = 64)),
    CONSTRAINT schema_migrations_owner_check CHECK ((owner = 'workspace'::text)),
    CONSTRAINT schema_migrations_version_check CHECK ((version >= 1))
);


ALTER TABLE workspace.schema_migrations OWNER TO sf_owner;

--
-- Name: TABLE schema_migrations; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.schema_migrations IS 'every migration applied to workspace.db.';


--
-- Name: COLUMN schema_migrations.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_migrations.id IS 'workspace/<version>';


--
-- Name: COLUMN schema_migrations.owner; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_migrations.owner IS 'only the workspace''s own tables live in this database';


--
-- Name: COLUMN schema_migrations.version; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_migrations.version IS '1 creates the tables from schema/workspace';


--
-- Name: COLUMN schema_migrations.checksum; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_migrations.checksum IS 'SHA-256 of what was applied, hex';


--
-- Name: COLUMN schema_migrations.applied_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.schema_migrations.applied_at IS 'when';


--
-- Name: workspace_identity; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.workspace_identity (
    id uuid DEFAULT uuidv7() NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    one boolean DEFAULT true NOT NULL,
    CONSTRAINT workspace_identity_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT workspace_identity_name_check CHECK (((length(name) >= 1) AND (length(name) <= 100))),
    CONSTRAINT workspace_identity_one_check CHECK (one)
);


ALTER TABLE workspace.workspace_identity OWNER TO sf_owner;

--
-- Name: TABLE workspace_identity; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.workspace_identity IS 'the workspace this database is, exactly one row. The workspace''s database (sf_workspace) holds what the workspace shares: the list of its schemas and the saved connections. Each schema is its own database, sf_<its id, hex> (decision 3).';


--
-- Name: COLUMN workspace_identity.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_identity.id IS 'UUIDv7, written when the workspace is made';


--
-- Name: COLUMN workspace_identity.name; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_identity.name IS 'its name, the name of its folder under ~/.schema-forge/workspaces/';


--
-- Name: COLUMN workspace_identity.created_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_identity.created_at IS 'when';


--
-- Name: COLUMN workspace_identity.one; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_identity.one IS 'keeps the table to one row';


--
-- Name: workspace_schemas; Type: TABLE; Schema: workspace; Owner: sf_owner
--

CREATE TABLE workspace.workspace_schemas (
    id uuid NOT NULL,
    name text NOT NULL,
    engine text NOT NULL,
    engine_version text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    opened_at timestamp with time zone,
    CONSTRAINT workspace_schemas_id_check CHECK ((uuid_extract_version(id) = 7)),
    CONSTRAINT workspace_schemas_name_check CHECK ((((length(name) >= 1) AND (length(name) <= 100)) AND (name ~ '^[A-Za-z0-9-][A-Za-z0-9_.-]*$'::text)))
);


ALTER TABLE workspace.workspace_schemas OWNER TO sf_owner;

--
-- Name: TABLE workspace_schemas; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON TABLE workspace.workspace_schemas IS 'every schema of the workspace, each in its own database, by its stable id (decision 4). The application keeps it equal to the databases: a database''s schema_identity row and its row here have the same id, name and engine.';


--
-- Name: COLUMN workspace_schemas.id; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.id IS 'the schema''s id, as its database''s schema_identity row holds it; its database is sf_<id, hex>';


--
-- Name: COLUMN workspace_schemas.name; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.name IS 'its name; a rename never moves its database';


--
-- Name: COLUMN workspace_schemas.engine; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.engine IS 'the id of its engine';


--
-- Name: COLUMN workspace_schemas.engine_version; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.engine_version IS 'the engine version it is designed for';


--
-- Name: COLUMN workspace_schemas.created_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.created_at IS 'when its database was made';


--
-- Name: COLUMN workspace_schemas.opened_at; Type: COMMENT; Schema: workspace; Owner: sf_owner
--

COMMENT ON COLUMN workspace.workspace_schemas.opened_at IS 'when it was last opened; NULL if never since it was listed';


--
-- Name: connection_test_steps connection_test_steps_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_test_steps
    ADD CONSTRAINT connection_test_steps_pkey PRIMARY KEY (id);


--
-- Name: connection_test_steps connection_test_steps_test_step_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_test_steps
    ADD CONSTRAINT connection_test_steps_test_step_key UNIQUE (test, step);


--
-- Name: connection_tests connection_tests_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_tests
    ADD CONSTRAINT connection_tests_pkey PRIMARY KEY (id);


--
-- Name: connection_values connection_values_connection_field_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_values
    ADD CONSTRAINT connection_values_connection_field_key UNIQUE (connection, field);


--
-- Name: connection_values connection_values_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_values
    ADD CONSTRAINT connection_values_pkey PRIMARY KEY (id);


--
-- Name: connections connections_name_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connections
    ADD CONSTRAINT connections_name_key UNIQUE (name);


--
-- Name: connections connections_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connections
    ADD CONSTRAINT connections_pkey PRIMARY KEY (id);


--
-- Name: parameters parameters_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.parameters
    ADD CONSTRAINT parameters_pkey PRIMARY KEY (id);


--
-- Name: schema_connections schema_connections_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_connections
    ADD CONSTRAINT schema_connections_pkey PRIMARY KEY (id);


--
-- Name: schema_connections schema_connections_schema_id_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_connections
    ADD CONSTRAINT schema_connections_schema_id_key UNIQUE (schema_id);


--
-- Name: schema_migrations schema_migrations_owner_version_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_migrations
    ADD CONSTRAINT schema_migrations_owner_version_key UNIQUE (owner, version);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (id);


--
-- Name: workspace_identity workspace_identity_one_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.workspace_identity
    ADD CONSTRAINT workspace_identity_one_key UNIQUE (one);


--
-- Name: workspace_identity workspace_identity_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.workspace_identity
    ADD CONSTRAINT workspace_identity_pkey PRIMARY KEY (id);


--
-- Name: workspace_schemas workspace_schemas_name_key; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.workspace_schemas
    ADD CONSTRAINT workspace_schemas_name_key UNIQUE (name);


--
-- Name: workspace_schemas workspace_schemas_pkey; Type: CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.workspace_schemas
    ADD CONSTRAINT workspace_schemas_pkey PRIMARY KEY (id);


--
-- Name: connection_test_steps connection_test_steps_test_fkey; Type: FK CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_test_steps
    ADD CONSTRAINT connection_test_steps_test_fkey FOREIGN KEY (test) REFERENCES workspace.connection_tests(id) ON DELETE CASCADE;


--
-- Name: connection_tests connection_tests_connection_fkey; Type: FK CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_tests
    ADD CONSTRAINT connection_tests_connection_fkey FOREIGN KEY (connection) REFERENCES workspace.connections(id) ON DELETE CASCADE;


--
-- Name: connection_values connection_values_connection_fkey; Type: FK CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.connection_values
    ADD CONSTRAINT connection_values_connection_fkey FOREIGN KEY (connection) REFERENCES workspace.connections(id) ON DELETE CASCADE;


--
-- Name: schema_connections schema_connections_connection_id_fkey; Type: FK CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_connections
    ADD CONSTRAINT schema_connections_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES workspace.connections(id) ON DELETE CASCADE;


--
-- Name: schema_connections schema_connections_schema_id_fkey; Type: FK CONSTRAINT; Schema: workspace; Owner: sf_owner
--

ALTER TABLE ONLY workspace.schema_connections
    ADD CONSTRAINT schema_connections_schema_id_fkey FOREIGN KEY (schema_id) REFERENCES workspace.workspace_schemas(id) ON DELETE CASCADE;


--
-- Name: SCHEMA workspace; Type: ACL; Schema: -; Owner: sf_owner
--

GRANT USAGE ON SCHEMA workspace TO sf_service;
GRANT USAGE ON SCHEMA workspace TO sf_reader;


--
-- Name: TABLE connection_test_steps; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.connection_test_steps TO sf_service;
GRANT SELECT ON TABLE workspace.connection_test_steps TO sf_reader;


--
-- Name: TABLE connection_tests; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.connection_tests TO sf_service;
GRANT SELECT ON TABLE workspace.connection_tests TO sf_reader;


--
-- Name: TABLE connection_values; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.connection_values TO sf_service;
GRANT SELECT ON TABLE workspace.connection_values TO sf_reader;


--
-- Name: TABLE connections; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.connections TO sf_service;
GRANT SELECT ON TABLE workspace.connections TO sf_reader;


--
-- Name: TABLE parameters; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.parameters TO sf_service;
GRANT SELECT ON TABLE workspace.parameters TO sf_reader;


--
-- Name: TABLE schema_connections; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.schema_connections TO sf_service;
GRANT SELECT ON TABLE workspace.schema_connections TO sf_reader;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.schema_migrations TO sf_service;
GRANT SELECT ON TABLE workspace.schema_migrations TO sf_reader;


--
-- Name: TABLE workspace_identity; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.workspace_identity TO sf_service;
GRANT SELECT ON TABLE workspace.workspace_identity TO sf_reader;


--
-- Name: TABLE workspace_schemas; Type: ACL; Schema: workspace; Owner: sf_owner
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE workspace.workspace_schemas TO sf_service;
GRANT SELECT ON TABLE workspace.workspace_schemas TO sf_reader;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: workspace; Owner: sf_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA workspace GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA workspace GRANT SELECT ON TABLES TO sf_reader;


--
-- PostgreSQL database dump complete
--
