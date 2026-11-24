-- cortex.relationship_columns: the column pairs of a relationship, in order: from_column refers to to_column. Owner: cortex.
CREATE TABLE cortex.relationship_columns (
  id            TEXT    NOT NULL PRIMARY KEY,                                             -- <relationship>.<n>, n given once from id_counters and never reused: l_orders_customer.1
  relationship  TEXT    NOT NULL REFERENCES cortex.relationships (id) ON DELETE CASCADE,  -- the relationship
  position      NUMERIC NOT NULL CHECK (position > 0),                                    -- the pair's place in the relationship; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  from_column   TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,        -- a column of the relationship's from_object
  to_column     TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,        -- a column of the relationship's to_object
  UNIQUE (relationship, position),
  CHECK (substr(id, 1, length(relationship) + 1) = relationship || '.' AND substr(id, length(relationship) + 2) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.relationship_columns IS 'the column pairs of a relationship, in order: from_column refers to to_column.';
COMMENT ON COLUMN cortex.relationship_columns.id IS '<relationship>.<n>, n given once from id_counters and never reused: l_orders_customer.1';
COMMENT ON COLUMN cortex.relationship_columns.relationship IS 'the relationship';
COMMENT ON COLUMN cortex.relationship_columns.position IS 'the pair''s place in the relationship; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.relationship_columns.from_column IS 'a column of the relationship''s from_object';
COMMENT ON COLUMN cortex.relationship_columns.to_column IS 'a column of the relationship''s to_object';
