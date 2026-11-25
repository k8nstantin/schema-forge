-- engine_mysql.tablespaces: a tablespace (CREATE TABLESPACE).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.tablespaces (
  id               TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the tablespace
  datafile         TEXT,                                                                        -- its data file (ADD DATAFILE); NULL when not written
  file_block_size  TEXT,                                                                        -- its file's block size; NULL when not written
  engine           TEXT,                                                                        -- its storage engine; NULL when not written
  encryption       TEXT                                                                         -- whether it is encrypted (Y, N); NULL when not written
);

COMMENT ON TABLE engine_mysql.tablespaces IS 'a tablespace (CREATE TABLESPACE). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.tablespaces.id IS 'the tablespace';
COMMENT ON COLUMN engine_mysql.tablespaces.datafile IS 'its data file (ADD DATAFILE); NULL when not written';
COMMENT ON COLUMN engine_mysql.tablespaces.file_block_size IS 'its file''s block size; NULL when not written';
COMMENT ON COLUMN engine_mysql.tablespaces.engine IS 'its storage engine; NULL when not written';
COMMENT ON COLUMN engine_mysql.tablespaces.encryption IS 'whether it is encrypted (Y, N); NULL when not written';
