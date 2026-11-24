-- engine_mysql.index_options: what MySQL says of an index beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.index_options (
  id                TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.indexes (id) ON DELETE CASCADE,  -- the index
  comment           TEXT,                                                                           -- what it is for; NULL when not written
  key_block_size    INTEGER CHECK (key_block_size >= 0),                                            -- its block size, in KB; NULL when not written
  parser            TEXT,                                                                           -- the full-text parser it uses (ngram); NULL when not written
  invisible         BOOLEAN  ,                                                                      -- true when the optimizer ignores it; NULL when not written
  engine_attribute  TEXT                                                                            -- what its storage engine is told about it; NULL when not written
);

COMMENT ON TABLE engine_mysql.index_options IS 'what MySQL says of an index beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.index_options.id IS 'the index';
COMMENT ON COLUMN engine_mysql.index_options.comment IS 'what it is for; NULL when not written';
COMMENT ON COLUMN engine_mysql.index_options.key_block_size IS 'its block size, in KB; NULL when not written';
COMMENT ON COLUMN engine_mysql.index_options.parser IS 'the full-text parser it uses (ngram); NULL when not written';
COMMENT ON COLUMN engine_mysql.index_options.invisible IS 'true when the optimizer ignores it; NULL when not written';
COMMENT ON COLUMN engine_mysql.index_options.engine_attribute IS 'what its storage engine is told about it; NULL when not written';
