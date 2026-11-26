-- cortex.object_kinds: the kinds of object each engine has, as it declares them; an object of a kind its design's engine does not declare is refused. Owner: cortex.
CREATE TABLE cortex.object_kinds (
  id        TEXT NOT NULL PRIMARY KEY,                      -- <engine>/<kind>: mysql/table
  engine    TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),  -- the engine
  kind      TEXT NOT NULL CHECK (kind ~ '^[a-z0-9_]+$'),    -- as an object names its kind (table, view, procedure, materialized_view)
  name      TEXT NOT NULL,                                  -- as people say it (Table)
  position  NUMERIC NOT NULL CHECK (position > 0),          -- its place in the engine's declaration, for listing in the engine's order
  UNIQUE (engine, kind),
  UNIQUE (engine, position),
  CHECK (id = engine || '/' || kind)
);

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object each engine has, as it declares them; an object of a kind its design''s engine does not declare is refused.';
COMMENT ON COLUMN cortex.object_kinds.id IS '<engine>/<kind>: mysql/table';
COMMENT ON COLUMN cortex.object_kinds.engine IS 'the engine';
COMMENT ON COLUMN cortex.object_kinds.kind IS 'as an object names its kind (table, view, procedure, materialized_view)';
COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';
COMMENT ON COLUMN cortex.object_kinds.position IS 'its place in the engine''s declaration, for listing in the engine''s order';
