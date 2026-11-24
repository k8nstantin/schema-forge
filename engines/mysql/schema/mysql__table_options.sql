-- mysql__table_options: the table options of a MySQL table (CREATE TABLE ... ENGINE=... ROW_FORMAT=...), each as MySQL writes it.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__table_options (
  id                          TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the table
  engine                      TEXT,       -- its storage engine (InnoDB, MyISAM); NULL when not written
  auto_increment              INTEGER CHECK (auto_increment >= 0),  -- the next number its AUTO_INCREMENT column gives; NULL when not written
  autoextend_size             TEXT,       -- how much its file grows at a time; NULL when not written
  avg_row_length              INTEGER CHECK (avg_row_length >= 0),  -- the row length it is sized for; NULL when not written
  charset                     TEXT,       -- its default character set; NULL when not written
  collation                   TEXT,       -- its default collation; NULL when not written
  checksum                    TEXT,       -- whether a live checksum of its rows is kept (0, 1); NULL when not written
  compression                 TEXT,       -- how its pages are compressed (zlib, lz4, none); NULL when not written
  "connection"                TEXT,       -- where a FEDERATED table's rows are; NULL when not written
  data_directory              TEXT,       -- where its data file is; NULL when not written
  index_directory             TEXT,       -- where its index file is; NULL when not written
  delay_key_write             TEXT,       -- whether index writes wait until it is closed (0, 1); NULL when not written
  encryption                  TEXT,       -- whether it is encrypted (Y, N); NULL when not written
  engine_attribute            TEXT,       -- what its storage engine is told about it; NULL when not written
  secondary_engine            TEXT,       -- the secondary engine it is loaded into; NULL when not written
  secondary_engine_attribute  TEXT,       -- what its secondary engine is told about it; NULL when not written
  insert_method               TEXT,       -- where a MERGE table inserts (NO, FIRST, LAST); NULL when not written
  key_block_size              INTEGER CHECK (key_block_size >= 0),  -- the size of its compressed pages, in KB; NULL when not written
  max_rows                    INTEGER CHECK (max_rows >= 0),        -- the most rows it is sized for; NULL when not written
  min_rows                    INTEGER CHECK (min_rows >= 0),        -- the fewest rows it is sized for; NULL when not written
  pack_keys                   TEXT,       -- whether its indexes are packed (0, 1, DEFAULT); NULL when not written
  row_format                  TEXT,       -- how its rows are stored (DYNAMIC, COMPACT, COMPRESSED, REDUNDANT, FIXED); NULL when not written
  stats_auto_recalc           TEXT,       -- whether its statistics are recalculated on their own (0, 1, DEFAULT); NULL when not written
  stats_persistent            TEXT,       -- whether its statistics are kept on disk (0, 1, DEFAULT); NULL when not written
  stats_sample_pages          TEXT,       -- how many pages its statistics sample; NULL when not written
  tablespace                  TEXT        -- the tablespace it is stored in, by name; NULL when not written
) STRICT;
