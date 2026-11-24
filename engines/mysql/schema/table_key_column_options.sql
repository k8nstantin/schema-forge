-- engine_mysql.table_key_column_options: how one column of a key is indexed where it is not the whole column ascending.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.table_key_column_options (
  id      TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.table_key_columns (id) ON DELETE CASCADE,  -- the key's column
  length  INTEGER CHECK (length >= 1),                                                              -- how many characters or bytes of it the key holds (b(10)); NULL for the whole column
  "desc"  BOOLEAN NOT NULL DEFAULT false,                                                           -- true when it is held descending (DESC)
  CHECK (length IS NOT NULL OR "desc")
);

COMMENT ON TABLE engine_mysql.table_key_column_options IS 'how one column of a key is indexed where it is not the whole column ascending. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.table_key_column_options.id IS 'the key''s column';
COMMENT ON COLUMN engine_mysql.table_key_column_options.length IS 'how many characters or bytes of it the key holds (b(10)); NULL for the whole column';
COMMENT ON COLUMN engine_mysql.table_key_column_options."desc" IS 'true when it is held descending (DESC)';
