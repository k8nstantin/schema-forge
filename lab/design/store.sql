-- The store: the global schema (core) and the MySQL plugin's (engine_mysql). Every other plugin adds its own
-- engine_<name> schema the same way. The log (lab/design/versioning.sql) versions every table of all of them.
--
-- Rules every table keeps:
--   every row has a bigint id; parts refer to each other by id, so a rename changes one row;
--   a plugin row extends one global row and has its id; it exists only where the engine holds something;
--   a table is held as facts only, its statement written from them; a program keeps two texts as written, its body
--   and (MySQL) its parameter list, everything else facts;
--   every reference is deferrable, so undo can put rows back in any order.

CREATE SCHEMA core;
CREATE SCHEMA engine_mysql;

-- ---------------------------------------------------------------- global

CREATE TABLE core.server (
  id      bigint PRIMARY KEY,
  engine  text   NOT NULL,                      -- the plugin that reads and writes it
  version text   NOT NULL,
  name    text   NOT NULL UNIQUE
);

-- MySQL has one level (database); PostgreSQL two (database, schema): each level a namespace under its parent.
CREATE TABLE core.namespace (
  id        bigint PRIMARY KEY,
  server_id bigint NOT NULL REFERENCES core.server (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  parent_id bigint REFERENCES core.namespace (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  name      text   NOT NULL,
  comment   text,
  UNIQUE NULLS NOT DISTINCT (server_id, parent_id, name) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.object (
  id           bigint PRIMARY KEY,
  namespace_id bigint NOT NULL REFERENCES core.namespace (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  parent_id    bigint REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- a trigger's table
  kind         text   NOT NULL CHECK (kind IN ('table', 'view', 'materialized view', 'procedure', 'function', 'trigger',
                                                 'event', 'sequence', 'type')),
  name         text   NOT NULL,
  signature    text   NOT NULL DEFAULT '',     -- the argument types of an overloaded routine; '' elsewhere
  comment      text,
  body         text,                            -- a program's body or a view's query, as the server holds it
  UNIQUE (namespace_id, kind, name, signature) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (id, kind)                             -- what a plugin row checks its kind against
);

CREATE TABLE core.column (
  id                    bigint  PRIMARY KEY,
  object_id             bigint  NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position              integer NOT NULL,
  name                  text    NOT NULL,
  type                  text    NOT NULL,      -- as the engine writes it
  nullable              boolean NOT NULL,
  default_value         text,
  default_is_expression boolean NOT NULL DEFAULT false,
  generated             text,                  -- a generated column's expression
  generated_stored      boolean,
  identity              text CHECK (identity IN ('auto', 'always', 'by default')),
  collation_name        text,
  comment               text,
  UNIQUE (object_id, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.index (
  id         bigint  PRIMARY KEY,
  object_id  bigint  NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  name       text    NOT NULL,
  position   integer NOT NULL,                 -- the order the table lists them in; information_schema sorts by name
  is_primary boolean NOT NULL DEFAULT false,
  is_unique  boolean NOT NULL DEFAULT false,
  method     text,                             -- the engine's word: BTREE, FULLTEXT, SPATIAL, gin, ...
  predicate  text,
  comment    text,
  UNIQUE (object_id, name) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.index_part (
  id         bigint  PRIMARY KEY,
  index_id   bigint  NOT NULL REFERENCES core.index (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position   integer NOT NULL,
  column_id  bigint  REFERENCES core.column (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  expression text,
  descending boolean NOT NULL DEFAULT false,
  CHECK ((column_id IS NULL) <> (expression IS NULL)),
  UNIQUE (index_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.constraint (
  id            bigint  PRIMARY KEY,
  object_id     bigint  NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  name          text    NOT NULL,
  kind          text    NOT NULL CHECK (kind IN ('primary', 'unique', 'foreign', 'check', 'exclusion', 'not null')),
  in_database   boolean NOT NULL DEFAULT true,   -- false: a link the design draws that the database does not hold
  enforced      boolean NOT NULL DEFAULT true,
  is_deferrable boolean NOT NULL DEFAULT false,
  is_deferred   boolean NOT NULL DEFAULT false,
  expression    text,                            -- a check's
  index_id      bigint  REFERENCES core.index (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  ref_object_id bigint  REFERENCES core.object (id) DEFERRABLE INITIALLY DEFERRED,  -- a referenced table cannot go
  ref_namespace text,                            -- what a foreign key names when its table is not in the store
  ref_object    text,
  on_delete     text,
  on_update     text,
  match         text,
  UNIQUE (object_id, kind, name) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.constraint_column (
  id            bigint  PRIMARY KEY,
  constraint_id bigint  NOT NULL REFERENCES core.constraint (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position      integer NOT NULL,
  column_id     bigint  NOT NULL REFERENCES core.column (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  ref_column_id bigint  REFERENCES core.column (id) DEFERRABLE INITIALLY DEFERRED,
  ref_column    text,                            -- when the referenced column is not in the store
  UNIQUE (constraint_id, position) DEFERRABLE INITIALLY DEFERRED
);

-- What an object uses: a view's tables, a routine's tables where the engine says. An edit names what it would break
-- from here; a body is text, so a rename never reaches into it.
CREATE TABLE core.dependency (
  id             bigint PRIMARY KEY,
  object_id      bigint NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  uses_object_id bigint NOT NULL REFERENCES core.object (id) DEFERRABLE INITIALLY DEFERRED,  -- a used table cannot go
  uses_column_id bigint REFERENCES core.column (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  UNIQUE NULLS NOT DISTINCT (object_id, uses_object_id, uses_column_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.routine (
  id            bigint  PRIMARY KEY,
  kind          text    NOT NULL CHECK (kind IN ('procedure', 'function')),
  returns       text,                            -- as the engine writes it
  language      text    NOT NULL DEFAULT 'SQL',
  deterministic boolean NOT NULL DEFAULT false,
  security      text    NOT NULL DEFAULT 'definer' CHECK (security IN ('definer', 'invoker')),
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

-- The server's reading of a routine's parameters, for search and the canvas. The writer uses the text as written.
CREATE TABLE core.parameter (
  id        bigint  PRIMARY KEY,
  object_id bigint  NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position  integer NOT NULL,
  name      text,
  mode      text,
  type      text    NOT NULL,
  UNIQUE (object_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.trigger (
  id      bigint PRIMARY KEY,
  kind    text   NOT NULL DEFAULT 'trigger' CHECK (kind = 'trigger'),
  timing  text   NOT NULL,                       -- BEFORE, AFTER, INSTEAD OF
  events  text[] NOT NULL,                       -- INSERT, UPDATE, DELETE, TRUNCATE
  level   text   NOT NULL DEFAULT 'row' CHECK (level IN ('row', 'statement')),
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.view (
  id           bigint PRIMARY KEY,
  kind         text   NOT NULL DEFAULT 'view' CHECK (kind IN ('view', 'materialized view')),
  check_option text   CHECK (check_option IN ('LOCAL', 'CASCADED')),
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.partitioning (
  id         bigint PRIMARY KEY REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  strategy   text   NOT NULL,                    -- RANGE, LIST, HASH, KEY, ...
  expression text   NOT NULL
);

CREATE TABLE core.partition (
  id        bigint  PRIMARY KEY,
  object_id bigint  NOT NULL REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position  integer NOT NULL,
  name      text    NOT NULL,
  bounds    text,
  table_id  bigint  REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- where a partition is a table
  comment   text,
  UNIQUE (object_id, name) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE core.sequence (
  id        bigint  PRIMARY KEY,
  kind      text    NOT NULL DEFAULT 'sequence' CHECK (kind = 'sequence'),
  type      text,
  start     numeric,
  increment numeric,
  minimum   numeric,
  maximum   numeric,
  cache     bigint,
  cycle     boolean NOT NULL DEFAULT false,
  owned_by  bigint  REFERENCES core.column (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

-- ---------------------------------------------------------------- MySQL

CREATE TABLE engine_mysql.namespace (
  id             bigint PRIMARY KEY REFERENCES core.namespace (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  collation_name text   NOT NULL,              -- the character set is the collation's
  encryption     boolean
);

CREATE TABLE engine_mysql.table (
  id                 bigint  PRIMARY KEY,
  kind               text    NOT NULL DEFAULT 'table' CHECK (kind = 'table'),
  engine             text    NOT NULL,
  collation_name     text    NOT NULL,
  row_format         text,                     -- each option only where the table's statement writes it
  avg_row_length     bigint,
  min_rows           bigint,
  max_rows           bigint,
  pack_keys          text,
  checksum           text,
  delay_key_write    text,
  key_block_size     integer,
  stats_persistent   text,
  stats_auto_recalc  text,
  stats_sample_pages text,
  compression        text,
  encryption         text,
  merge_union        text[],                   -- SHOW CREATE alone holds these two
  insert_method      text,
  CHECK ((merge_union IS NULL AND insert_method IS NULL) OR engine = 'MRG_MyISAM'),  -- the MERGE engine's alone
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE engine_mysql.column (
  id        bigint  PRIMARY KEY REFERENCES core.column (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  on_update text,
  srid      integer,
  invisible boolean NOT NULL DEFAULT false
);

CREATE TABLE engine_mysql.index (
  id        bigint  PRIMARY KEY REFERENCES core.index (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  invisible boolean NOT NULL DEFAULT false
);

CREATE TABLE engine_mysql.index_part (
  id            bigint  PRIMARY KEY REFERENCES core.index_part (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  prefix_length integer NOT NULL
);

CREATE TABLE engine_mysql.subpartitioning (
  id         bigint PRIMARY KEY REFERENCES core.partitioning (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  method     text   NOT NULL,
  expression text   NOT NULL
);

CREATE TABLE engine_mysql.subpartition (
  id           bigint  PRIMARY KEY,
  partition_id bigint  NOT NULL REFERENCES core.partition (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  position     integer NOT NULL,
  name         text    NOT NULL,
  UNIQUE (partition_id, position) DEFERRABLE INITIALLY DEFERRED
);

-- What every MySQL program is made under. The server runs it under these, and writing it back must set them.
CREATE TABLE engine_mysql.program (
  id                   bigint PRIMARY KEY REFERENCES core.object (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  definer              text   NOT NULL,
  sql_mode             text,                 -- as SHOW CREATE gives it (5.7's ROUTINES misnames one mode); none for a view
  character_set_client text   NOT NULL,
  collation_connection text   NOT NULL,
  database_collation   text,
  time_zone            text                  -- events
);

CREATE TABLE engine_mysql.routine (
  id             bigint PRIMARY KEY REFERENCES core.routine (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  parameter_text text   NOT NULL,          -- the parameter list as written: real code formats it by hand
  data_access    text   NOT NULL DEFAULT 'CONTAINS SQL',
  returns_charset text,
  parameter_collation text                 -- what its untyped character parameters took: the collation of the
                                           -- database current when it was made, not always its own
);

CREATE TABLE engine_mysql.view (
  id        bigint PRIMARY KEY REFERENCES core.view (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  algorithm text   NOT NULL DEFAULT 'UNDEFINED',  -- SHOW CREATE VIEW alone holds it
  security  text   NOT NULL DEFAULT 'DEFINER'
);

CREATE TABLE engine_mysql.trigger (
  id           bigint  PRIMARY KEY REFERENCES core.trigger (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  action_order integer NOT NULL DEFAULT 1
);

CREATE TABLE engine_mysql.event (
  id             bigint  PRIMARY KEY,
  kind           text    NOT NULL DEFAULT 'event' CHECK (kind = 'event'),
  interval_value text,                       -- EVERY value field, or AT execute_at
  interval_field text,
  execute_at     timestamp,
  starts         timestamp,
  ends           timestamp,
  status         text    NOT NULL,           -- ENABLE, DISABLE, DISABLE ON SLAVE
  on_completion  text    NOT NULL,           -- PRESERVE, NOT PRESERVE
  FOREIGN KEY (id, kind) REFERENCES core.object (id, kind) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
