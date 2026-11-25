-- engine_mysql.column_options: what MySQL says of a column beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.column_options (
  id           TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.columns (id) ON DELETE CASCADE,  -- the column
  charset      TEXT,                                                                           -- its character set; NULL when not written
  "collation"  TEXT,                                                                           -- its collation; NULL when not written
  "binary"     BOOLEAN,                                                                        -- true when it uses its character set's binary collation (BINARY, deprecated); NULL when not written
  on_update    TEXT,                                                                           -- what it becomes whenever its row changes (ON UPDATE CURRENT_TIMESTAMP); NULL for none
  srid         INTEGER CHECK (srid >= 0),                                                      -- the spatial reference system of its shapes; NULL for none
  invisible    BOOLEAN                                                                         -- true when SELECT * leaves it out; NULL when not written
);

COMMENT ON TABLE engine_mysql.column_options IS 'what MySQL says of a column beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.column_options.id IS 'the column';
COMMENT ON COLUMN engine_mysql.column_options.charset IS 'its character set; NULL when not written';
COMMENT ON COLUMN engine_mysql.column_options."collation" IS 'its collation; NULL when not written';
COMMENT ON COLUMN engine_mysql.column_options."binary" IS 'true when it uses its character set''s binary collation (BINARY, deprecated); NULL when not written';
COMMENT ON COLUMN engine_mysql.column_options.on_update IS 'what it becomes whenever its row changes (ON UPDATE CURRENT_TIMESTAMP); NULL for none';
COMMENT ON COLUMN engine_mysql.column_options.srid IS 'the spatial reference system of its shapes; NULL for none';
COMMENT ON COLUMN engine_mysql.column_options.invisible IS 'true when SELECT * leaves it out; NULL when not written';
