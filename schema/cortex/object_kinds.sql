-- cortex.object_kinds: the kinds of object this schema's engine has, as the engine declares them. Owner: cortex.
-- Written from the engine's declaration when the database is made and when the engine's version of the schema changes;
-- an object of a kind not here is refused by objects.kind, and a part its kind's slots (object_kind_parts) lack by integrity.sql.
CREATE TABLE cortex.object_kinds (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z0-9_]+$'),           -- as an object names its kind (table, view, record)
  name      TEXT    NOT NULL,                                                   -- as people say it (Table)
  position  NUMERIC NOT NULL UNIQUE CHECK (position > 0)                        -- its place in the engine's declaration, for listing in the engine's order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
);

COMMENT ON TABLE cortex.object_kinds IS 'the kinds of object this schema''s engine has, as the engine declares them. Written from the engine''s declaration when the database is made and when the engine''s version of the schema changes; an object of a kind not here is refused by objects.kind, and a part its kind''s slots (object_kind_parts) lack by integrity.sql.';
COMMENT ON COLUMN cortex.object_kinds.id IS 'as an object names its kind (table, view, record)';
COMMENT ON COLUMN cortex.object_kinds.name IS 'as people say it (Table)';
COMMENT ON COLUMN cortex.object_kinds.position IS 'its place in the engine''s declaration, for listing in the engine''s order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
