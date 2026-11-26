-- cortex.object_kinds: the kinds of object each engine has, as it declares them; an object of a kind its design's engine does not declare is refused. Owner: cortex.
CREATE TABLE cortex.object_kinds (
  id        TEXT NOT NULL PRIMARY KEY,                      -- <engine>/<kind>: mysql/table
  engine    TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),  -- the engine
  kind      TEXT NOT NULL CHECK (kind ~ '^[a-z0-9_]+$'),    -- as an object names its kind (table, view, procedure, materialized_view)
  name      TEXT NOT NULL CHECK (length(name) >= 1),        -- as people say it (Table)
  position  NUMERIC NOT NULL CHECK (position > 0),          -- its place in the engine's declaration, for listing in the engine's order
  scope     TEXT NOT NULL DEFAULT 'namespace' CHECK (scope IN ('namespace', 'database', 'server')),  -- where its objects live: in a namespace (a table), in the database outside any (a PostgreSQL cast), or in the server (a MySQL tablespace)
  flavor    TEXT,                                           -- the one flavor that has it (postgresql/spanner's change streams); NULL for every flavor of the engine
  since     TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,  -- the first version that has it (mysql/9.7 for a library); NULL for every one
  "until"   TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,  -- the last version that has it; NULL for every later one
  UNIQUE (engine, kind),
  UNIQUE (engine, position),
  FOREIGN KEY (flavor) REFERENCES cortex.engine_flavors (id) DEFERRABLE INITIALLY DEFERRED,
  CHECK (flavor LIKE engine || '/%'),
  CHECK (id = engine || '/' || kind)
);

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object each engine has, as it declares them; an object of a kind its design''s engine does not declare is refused.';
COMMENT ON COLUMN cortex.object_kinds.id IS '<engine>/<kind>: mysql/table';
COMMENT ON COLUMN cortex.object_kinds.engine IS 'the engine';
COMMENT ON COLUMN cortex.object_kinds.kind IS 'as an object names its kind (table, view, procedure, materialized_view)';
COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';
COMMENT ON COLUMN cortex.object_kinds.position IS 'its place in the engine''s declaration, for listing in the engine''s order';
COMMENT ON COLUMN cortex.object_kinds.scope IS 'where its objects live: in a namespace (a table), in the database outside any (a PostgreSQL cast), or in the server (a MySQL tablespace)';
COMMENT ON COLUMN cortex.object_kinds.since IS 'the first version that has it (mysql/9.7 for a library); NULL for every one';
COMMENT ON COLUMN cortex.object_kinds."until" IS 'the last version that has it; NULL for every later one';
COMMENT ON COLUMN cortex.object_kinds.flavor IS 'the one flavor that has it (postgresql/spanner''s change streams); NULL for every flavor of the engine';
