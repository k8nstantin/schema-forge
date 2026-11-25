-- engine_mysql.table_options: the table options of a MySQL table (CREATE TABLE ... ENGINE=... ROW_FORMAT=...), each as MySQL writes it.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.table_options (
  id              TEXT   NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table
  engine          TEXT,                                                                          -- its storage engine (InnoDB, MyISAM); NULL when not written
  auto_increment  BIGINT CHECK (auto_increment >= 0),                                            -- the next number its AUTO_INCREMENT column gives; NULL when not written
  charset         TEXT,                                                                          -- its default character set; NULL when not written
  "collation"     TEXT,                                                                          -- its default collation; NULL when not written
  compression     TEXT,                                                                          -- how its pages are compressed (zlib, lz4, none); NULL when not written
  encryption      TEXT,                                                                          -- whether it is encrypted (Y, N); NULL when not written
  row_format      TEXT,                                                                          -- how its rows are stored (DYNAMIC, COMPACT, COMPRESSED, REDUNDANT, FIXED); NULL when not written
  tablespace      TEXT                                                                           -- the tablespace it is stored in, by name; NULL when not written
);

COMMENT ON TABLE engine_mysql.table_options IS 'the table options of a MySQL table (CREATE TABLE ... ENGINE=... ROW_FORMAT=...), each as MySQL writes it. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.table_options.id IS 'the table';
COMMENT ON COLUMN engine_mysql.table_options.engine IS 'its storage engine (InnoDB, MyISAM); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.auto_increment IS 'the next number its AUTO_INCREMENT column gives; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.charset IS 'its default character set; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options."collation" IS 'its default collation; NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.compression IS 'how its pages are compressed (zlib, lz4, none); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.encryption IS 'whether it is encrypted (Y, N); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.row_format IS 'how its rows are stored (DYNAMIC, COMPACT, COMPRESSED, REDUNDANT, FIXED); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_options.tablespace IS 'the tablespace it is stored in, by name; NULL when not written';
