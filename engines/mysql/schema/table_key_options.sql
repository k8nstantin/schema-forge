-- engine_mysql.table_key_options: what MySQL says of a primary or unique key beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.table_key_options (
  id                TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.table_keys (id) ON DELETE CASCADE,  -- the key
  method            TEXT    CHECK (method IN ('BTREE', 'HASH')),                -- how it is built (USING); NULL when not written
  comment           TEXT,                                                       -- what it is for; NULL when not written
  key_block_size    INTEGER CHECK (key_block_size >= 0),                        -- its block size, in KB; NULL when not written
  invisible         BOOLEAN,                                                    -- true when the optimizer ignores it; NULL when not written
  engine_attribute  TEXT                                                        -- what its storage engine is told about it; NULL when not written
);

COMMENT ON TABLE engine_mysql.table_key_options IS 'what MySQL says of a primary or unique key beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.table_key_options.id IS 'the key';
COMMENT ON COLUMN engine_mysql.table_key_options.method IS 'how it is built (USING); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_key_options.comment IS 'what it is for; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_key_options.key_block_size IS 'its block size, in KB; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_key_options.invisible IS 'true when the optimizer ignores it; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_key_options.engine_attribute IS 'what its storage engine is told about it; NULL when not written';
