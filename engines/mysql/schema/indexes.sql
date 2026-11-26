-- engine_mysql.indexes: what MySQL says of an index beyond the cortex; a row only where it says something. Owner: mysql.
CREATE TABLE engine_mysql.indexes (
  id         BIGINT NOT NULL PRIMARY KEY,                                                                   -- the index
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  invisible  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when the optimizer ignores it (8.0 and later)
  parser     TEXT,                                                                                          -- the full-text parser it uses (ngram); NULL for none
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.indexes IS 'what MySQL says of an index beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_mysql.indexes.id IS 'the index';
COMMENT ON COLUMN engine_mysql.indexes.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.indexes.invisible IS 'true when the optimizer ignores it (8.0 and later)';
COMMENT ON COLUMN engine_mysql.indexes.parser IS 'the full-text parser it uses (ngram); NULL for none';
