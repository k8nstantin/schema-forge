-- engine_mysql.indexes: what MySQL says of an index beyond the cortex (its method, BTREE or HASH, and its uniqueness are the cortex's).
CREATE TABLE engine_mysql.indexes (
  id                          UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex index
  design                      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  kind                        TEXT NOT NULL DEFAULT 'index' CHECK (kind IN ('index', 'fulltext', 'spatial')),                   -- a plain index, a FULLTEXT or a SPATIAL one
  parser                      TEXT,                                                                                            -- a FULLTEXT index's WITH PARSER (ngram); NULL for none
  key_block_size              INTEGER CHECK (key_block_size > 0),                                                              -- KEY_BLOCK_SIZE, where written
  invisible                   BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when INVISIBLE (8.0 and later)
  engine_attribute            TEXT,                                                                                            -- ENGINE_ATTRIBUTE, where written
  secondary_engine_attribute  TEXT,                                                                                            -- SECONDARY_ENGINE_ATTRIBUTE, where written
  flavor_options              JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  CHECK (parser IS NULL OR kind = 'fulltext'),
  FOREIGN KEY (design, id) REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
