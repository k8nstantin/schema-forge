-- engine_postgresql.indexes: what PostgreSQL says of an index beyond the cortex; a row only where it says something. Owner: postgresql.
CREATE TABLE engine_postgresql.indexes (
  id                  UUID NOT NULL PRIMARY KEY,                                                                     -- the index
  design              UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  nulls_not_distinct  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when nulls count as equal (15 and later)
  options             JSONB,                                                                                         -- its storage options as the server writes them (["pages_per_range=32"]); NULL for none
  parent              UUID,                                                                                          -- the partitioned table's index it is part of; NULL for none
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX indexes_parent ON engine_postgresql.indexes (design, parent);

COMMENT ON TABLE engine_postgresql.indexes IS 'what PostgreSQL says of an index beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_postgresql.indexes.id IS 'the index';
COMMENT ON COLUMN engine_postgresql.indexes.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.indexes.nulls_not_distinct IS 'true when nulls count as equal (15 and later)';
COMMENT ON COLUMN engine_postgresql.indexes.options IS 'its storage options as the server writes them (["pages_per_range=32"]); NULL for none';
COMMENT ON COLUMN engine_postgresql.indexes.parent IS 'the partitioned table''s index it is part of; NULL for none';
