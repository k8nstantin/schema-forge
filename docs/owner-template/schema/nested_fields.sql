-- engine_example.nested_fields: the fields inside a column of a nested type (a struct of structs), as a tree. Owner: example.
-- Shape 4, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a
-- column's whole tree is one query and deleting the column deletes it.
CREATE TABLE engine_example.nested_fields (
  id        UUID    NOT NULL PRIMARY KEY DEFAULT uuidv7(),                                                 -- a UUIDv7 made with its row
  "column"  UUID    NOT NULL,                                                                              -- the column the tree belongs to
  parent    UUID,                                                                                          -- the field it sits in; NULL at the top of the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among its parent's fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                                                    -- its name
  type      TEXT    NOT NULL CHECK (length(type) >= 1),                                                    -- its type, as the engine writes it
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  CHECK (parent IS NULL OR parent <> id),
  UNIQUE (design, id),
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE,
  FOREIGN KEY (design, parent) REFERENCES engine_example.nested_fields (design, id) ON DELETE CASCADE
);

CREATE INDEX nested_fields_column ON engine_example.nested_fields (design, "column");
CREATE INDEX nested_fields_parent ON engine_example.nested_fields (design, parent);
CREATE UNIQUE INDEX nested_fields_place ON engine_example.nested_fields ("column", coalesce(parent, 0), position);  -- one field per place, at the top too

COMMENT ON TABLE engine_example.nested_fields IS 'the fields inside a column of a nested type (a struct of structs), as a tree. Shape 4, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a column''s whole tree is one query and deleting the column deletes it.';
COMMENT ON COLUMN engine_example.nested_fields.id IS 'issued by the database';
COMMENT ON COLUMN engine_example.nested_fields.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_example.nested_fields."column" IS 'the column the tree belongs to';
COMMENT ON COLUMN engine_example.nested_fields.parent IS 'the field it sits in; NULL at the top of the column';
COMMENT ON COLUMN engine_example.nested_fields.position IS 'its place among its parent''s fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.nested_fields.name IS 'its name';
COMMENT ON COLUMN engine_example.nested_fields.type IS 'its type, as the engine writes it';
