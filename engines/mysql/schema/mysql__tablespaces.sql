-- mysql__tablespaces: a tablespace (CREATE TABLESPACE).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__tablespaces (
  id                TEXT  NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the tablespace
  datafile          TEXT,  -- its data file (ADD DATAFILE); NULL when not written
  file_block_size   TEXT,  -- its file's block size; NULL when not written
  engine            TEXT,  -- its storage engine; NULL when not written
  autoextend_size   TEXT,  -- how much its file grows at a time; NULL when not written
  encryption        TEXT,  -- whether it is encrypted (Y, N); NULL when not written
  engine_attribute  TEXT   -- what its storage engine is told about it; NULL when not written
) STRICT;
