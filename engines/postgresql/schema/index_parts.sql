-- engine_postgresql.index_parts: how one part of an index is ordered and compared, where it is not the default. Owner: postgresql.
CREATE TABLE engine_postgresql.index_parts (
  id              BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.index_parts (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the index part
  nulls_first     BOOLEAN NOT NULL DEFAULT false,                                                                                  -- true when nulls sort first
  operator_class  TEXT,                                                                                                            -- its operator class where it is not the default for its type, as the server writes it (gist_trgm_ops); NULL for the default
  "collation"     TEXT                                                                                                             -- its collation where it is not its column's or expression's; NULL for that one
);

COMMENT ON TABLE engine_postgresql.index_parts IS 'how one part of an index is ordered and compared, where it is not the default.';
COMMENT ON COLUMN engine_postgresql.index_parts.id IS 'the index part';
COMMENT ON COLUMN engine_postgresql.index_parts.nulls_first IS 'true when nulls sort first';
COMMENT ON COLUMN engine_postgresql.index_parts.operator_class IS 'its operator class where it is not the default for its type, as the server writes it (gist_trgm_ops); NULL for the default';
COMMENT ON COLUMN engine_postgresql.index_parts."collation" IS 'its collation where it is not its column''s or expression''s; NULL for that one';
