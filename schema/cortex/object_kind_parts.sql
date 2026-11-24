-- cortex.object_kind_parts: the parts an object of each kind may have, as the engine declares them; any other part is refused. Owner: cortex.
-- Written from the engine's declaration of its kinds with the database; the slots are the section layout's
-- (crates/engine/src/kinds.rs Slot).
CREATE TABLE cortex.object_kind_parts (
  id    TEXT NOT NULL PRIMARY KEY,                                              -- <kind>.<slot>: table.keys
  kind  TEXT NOT NULL REFERENCES cortex.object_kinds (id) ON DELETE CASCADE,    -- the kind
  slot  TEXT NOT NULL CHECK (slot IN ('keys', 'checks', 'indexes', 'partitioning', 'partition_of', 'order', 'query', 'sequence', 'values', 'domain', 'fields', 'routine', 'trigger', 'event')),  -- a part it may have
  UNIQUE (kind, slot),
  CHECK (id = kind || '.' || slot)
);

COMMENT ON TABLE cortex.object_kind_parts IS 'the parts an object of each kind may have, as the engine declares them; any other part is refused. Written from the engine''s declaration of its kinds with the database; the slots are the section layout''s (crates/engine/src/kinds.rs Slot).';
COMMENT ON COLUMN cortex.object_kind_parts.id IS '<kind>.<slot>: table.keys';
COMMENT ON COLUMN cortex.object_kind_parts.kind IS 'the kind';
COMMENT ON COLUMN cortex.object_kind_parts.slot IS 'a part it may have';
