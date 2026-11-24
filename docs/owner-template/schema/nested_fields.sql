-- engine_example.nested_fields: the fields inside a column of a nested type (a struct of structs), as a tree. Owner: example.
-- Shape 5, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a
-- column's whole tree is one query and deleting the column deletes it.
CREATE TABLE engine_example.nested_fields (
  id        TEXT    NOT NULL PRIMARY KEY,                                            -- <column>.field<n>, n given once from id_counters and never reused: c_events_payload.field3
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,       -- the column the tree belongs to
  parent    TEXT    REFERENCES engine_example.nested_fields (id) ON DELETE CASCADE,  -- the field it sits in; NULL at the top of the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                   -- its place among its parent's fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                              -- its name
  type      TEXT    NOT NULL CHECK (length(type) >= 1),                              -- its type, as the engine writes it
  CHECK (parent IS NULL OR parent <> id),
  CHECK (substr(id, 1, length("column") + 6) = "column" || '.field' AND substr(id, length("column") + 7) ~ '^[1-9][0-9]*$')
);
CREATE UNIQUE INDEX nested_fields_place ON engine_example.nested_fields ("column", coalesce(parent, ''), position);  -- one field per place, at the top too

COMMENT ON TABLE engine_example.nested_fields IS 'the fields inside a column of a nested type (a struct of structs), as a tree. Shape 5, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a column''s whole tree is one query and deleting the column deletes it.';
COMMENT ON COLUMN engine_example.nested_fields.id IS '<column>.field<n>, n given once from id_counters and never reused: c_events_payload.field3';
COMMENT ON COLUMN engine_example.nested_fields."column" IS 'the column the tree belongs to';
COMMENT ON COLUMN engine_example.nested_fields.parent IS 'the field it sits in; NULL at the top of the column';
COMMENT ON COLUMN engine_example.nested_fields.position IS 'its place among its parent''s fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.nested_fields.name IS 'its name';
COMMENT ON COLUMN engine_example.nested_fields.type IS 'its type, as the engine writes it';
