-- engine_postgresql.indexes: what PostgreSQL says of an index beyond the cortex; a row only where it says something. Owner: postgresql.
CREATE TABLE engine_postgresql.indexes (
  id                  BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.indexes (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the index
  nulls_not_distinct  BOOLEAN NOT NULL DEFAULT false,                                                                              -- true when nulls count as equal (15 and later)
  options             JSONB,                                                                                                       -- its storage options as the server writes them (["pages_per_range=32"]); NULL for none
  parent              BIGINT REFERENCES cortex.indexes (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED                        -- the partitioned table's index it is part of; NULL for none
);

COMMENT ON TABLE engine_postgresql.indexes IS 'what PostgreSQL says of an index beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_postgresql.indexes.id IS 'the index';
COMMENT ON COLUMN engine_postgresql.indexes.nulls_not_distinct IS 'true when nulls count as equal (15 and later)';
COMMENT ON COLUMN engine_postgresql.indexes.options IS 'its storage options as the server writes them (["pages_per_range=32"]); NULL for none';
COMMENT ON COLUMN engine_postgresql.indexes.parent IS 'the partitioned table''s index it is part of; NULL for none';
