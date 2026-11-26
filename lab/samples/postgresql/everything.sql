-- PostgreSQL sample: one of every kind of object pg_dump --schema-only writes, and the cluster's own (a tablespace, a
-- role), so the design is measured against PostgreSQL's own idea of a database's structure, not against a list of
-- ours. PostgreSQL 15 and later. Roles are made without passwords: no capture ever holds one. The tablespace every_space
-- is made by lab/setup.py, which makes its folder first.
CREATE ROLE every_owner NOLOGIN;
CREATE ROLE every_reader NOLOGIN;
CREATE SCHEMA every AUTHORIZATION every_owner;
COMMENT ON SCHEMA every IS 'one of every kind';
CREATE EXTENSION IF NOT EXISTS hstore SCHEMA every;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- types: a base type's shell needs C functions, so the base kinds here are the ones SQL can make
CREATE TYPE every.mood AS ENUM ('sad', 'ok', 'happy');
CREATE TYPE every.pair AS (a int, b text);
CREATE DOMAIN every.positive AS int CHECK (VALUE > 0) DEFAULT 1;
CREATE TYPE every.floatrange AS RANGE (subtype = float8, multirange_type_name = every.floatmultirange);
CREATE COLLATION every.nocase (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

-- tables of every sort
CREATE TABLE every.parent (id int PRIMARY KEY, mood every.mood, tags every.hstore, size every.positive);
CREATE UNLOGGED TABLE every.scratch (id int, note text COLLATE every.nocase);
CREATE TABLE every.measures (id int, at date NOT NULL, v numeric) PARTITION BY RANGE (at);
CREATE TABLE every.measures_2026 PARTITION OF every.measures FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE every.child () INHERITS (every.parent);
CREATE TABLE every.typed OF every.pair (PRIMARY KEY (a));
CREATE STATISTICS every.parent_stats (ndistinct, dependencies) ON id, size FROM every.parent;
CREATE INDEX parent_mood ON every.parent (mood) WITH (fillfactor = 80);
ALTER TABLE every.parent ALTER COLUMN mood SET STATISTICS 500;
ALTER TABLE every.parent OWNER TO every_owner;

-- routines of every sort
CREATE FUNCTION every.add(a int, b int) RETURNS int LANGUAGE sql IMMUTABLE RETURN a + b;
CREATE FUNCTION every.sum_state(s int, v int) RETURNS int LANGUAGE sql IMMUTABLE RETURN coalesce(s, 0) + v;
CREATE AGGREGATE every.total(int) (SFUNC = every.sum_state, STYPE = int, INITCOND = '0');
CREATE PROCEDURE every.touch(p int) LANGUAGE plpgsql AS $$ BEGIN PERFORM p; END $$;
CREATE FUNCTION every.on_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'ddl'; END $$;
CREATE EVENT TRIGGER every_ddl ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION every.on_ddl();
ALTER EVENT TRIGGER every_ddl DISABLE;

-- operators and how indexes use them
CREATE FUNCTION every.mood_eq(a every.mood, b every.mood) RETURNS bool LANGUAGE sql IMMUTABLE RETURN a = b;
CREATE OPERATOR every.=== (LEFTARG = every.mood, RIGHTARG = every.mood, FUNCTION = every.mood_eq, COMMUTATOR = OPERATOR(every.===));
CREATE OPERATOR FAMILY every.mood_family USING btree;
CREATE FUNCTION every.int_cmp(a int, b int) RETURNS int LANGUAGE sql IMMUTABLE RETURN CASE WHEN a < b THEN -1 WHEN a > b THEN 1 ELSE 0 END;
CREATE OPERATOR CLASS every.int_reverse FOR TYPE int USING btree AS
  OPERATOR 1 > , OPERATOR 2 >= , OPERATOR 3 = , OPERATOR 4 <= , OPERATOR 5 < , FUNCTION 1 every.int_cmp(int, int);
CREATE CAST (every.pair AS text) WITH INOUT;
CREATE CONVERSION every.latin_to_utf8 FOR 'LATIN1' TO 'UTF8' FROM iso8859_1_to_utf8;

-- text search, all four kinds
CREATE TEXT SEARCH DICTIONARY every.simple_dict (TEMPLATE = pg_catalog.simple, STOPWORDS = english);
CREATE TEXT SEARCH CONFIGURATION every.plain (COPY = pg_catalog.simple);
ALTER TEXT SEARCH CONFIGURATION every.plain ALTER MAPPING FOR word WITH every.simple_dict;
CREATE TEXT SEARCH TEMPLATE every.tmpl (LEXIZE = dsimple_lexize, INIT = dsimple_init);
CREATE TEXT SEARCH PARSER every.prs (START = prsd_start, GETTOKEN = prsd_nexttoken, END = prsd_end, LEXTYPES = prsd_lextype);

-- the world outside: foreign data
CREATE SERVER every_remote FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', dbname 'engine_postgresql');
CREATE USER MAPPING FOR every_owner SERVER every_remote OPTIONS (user 'every_owner');
CREATE FOREIGN TABLE every.remote_parent (id int, mood text) SERVER every_remote OPTIONS (schema_name 'every', table_name 'parent');

-- replication
CREATE PUBLICATION every_pub FOR TABLE every.parent WITH (publish = 'insert, update');

-- access, as definitions: privileges, default privileges, row security
GRANT USAGE ON SCHEMA every TO every_reader;
GRANT SELECT ON every.parent TO every_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE every_owner IN SCHEMA every GRANT SELECT ON TABLES TO every_reader;
ALTER TABLE every.parent ENABLE ROW LEVEL SECURITY;
CREATE POLICY readers ON every.parent FOR SELECT TO every_reader USING (size > 0);

-- the rest a schema may hold
CREATE MATERIALIZED VIEW every.moods AS SELECT mood, count(*) FROM every.parent GROUP BY mood WITH NO DATA;
CREATE VIEW every.happy AS SELECT * FROM every.parent WHERE mood = 'happy';
CREATE RULE no_delete AS ON DELETE TO every.happy DO INSTEAD NOTHING;
CREATE SEQUENCE every.ticket AS bigint START 100 INCREMENT 5 CACHE 10;
CREATE ACCESS METHOD every_heap TYPE TABLE HANDLER heap_tableam_handler;
COMMENT ON TABLE every.parent IS 'the parent';
CREATE TABLE every.spaced (id int PRIMARY KEY) TABLESPACE every_space;
CREATE LANGUAGE every_plpgsql HANDLER plpgsql_call_handler INLINE plpgsql_inline_handler VALIDATOR plpgsql_validator;
COMMENT ON LANGUAGE every_plpgsql IS 'PL/pgSQL under another name';
CREATE SUBSCRIPTION every_sub CONNECTION 'host=publisher.example dbname=engine_postgresql user=replicator' PUBLICATION every_pub
  WITH (connect = false, enabled = false, create_slot = false, slot_name = NONE, binary = true);
