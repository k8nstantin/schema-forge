-- engine_mysql.tables: a table, with every table option MySQL 5.7 to 9.7 writes, each only where its statement writes it (SHOW CREATE TABLE); its columns, keys and indexes are the cortex's, with their MySQL details beside them.
CREATE TABLE engine_mysql.tables (
  id                          UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design                      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  engine                      TEXT NOT NULL CHECK (length(engine) >= 1),                                                       -- its storage engine as the server names it (InnoDB, MyISAM, MRG_MYISAM, MEMORY, ARCHIVE, CSV, BLACKHOLE, FEDERATED)
  "collation"                 TEXT NOT NULL,                                                                                   -- its default collation; its character set is the collation's
  row_format                  TEXT,                                                                                            -- ROW_FORMAT, where written (DYNAMIC, COMPACT, COMPRESSED, REDUNDANT, FIXED)
  auto_increment              BIGINT CHECK (auto_increment >= 1),                                                              -- the next AUTO_INCREMENT value the statement writes; NULL where not written
  avg_row_length              BIGINT,                                                                                          -- AVG_ROW_LENGTH, where written
  min_rows                    BIGINT,                                                                                          -- MIN_ROWS, where written
  max_rows                    BIGINT,                                                                                          -- MAX_ROWS, where written
  pack_keys                   TEXT CHECK (pack_keys IN ('0', '1', 'DEFAULT')),                                                -- PACK_KEYS, where written
  checksum                    BOOLEAN,                                                                                         -- CHECKSUM, where written
  delay_key_write             BOOLEAN,                                                                                         -- DELAY_KEY_WRITE, where written
  key_block_size              INTEGER CHECK (key_block_size > 0),                                                              -- KEY_BLOCK_SIZE, where written
  stats_persistent            TEXT CHECK (stats_persistent IN ('0', '1', 'DEFAULT')),                                          -- STATS_PERSISTENT, where written
  stats_auto_recalc           TEXT CHECK (stats_auto_recalc IN ('0', '1', 'DEFAULT')),                                         -- STATS_AUTO_RECALC, where written
  stats_sample_pages          TEXT,                                                                                            -- STATS_SAMPLE_PAGES, where written (a number or DEFAULT)
  compression                 TEXT,                                                                                            -- COMPRESSION, where written (zlib, lz4, none)
  encryption                  BOOLEAN,                                                                                         -- ENCRYPTION, where written
  tablespace                  TEXT,                                                                                            -- TABLESPACE, where written: a tablespace of the server, or innodb_system, innodb_file_per_table
  storage                     TEXT CHECK (storage IN ('DISK', 'MEMORY')),                                                      -- STORAGE with its tablespace, where written
  data_directory              TEXT,                                                                                            -- DATA DIRECTORY, where written
  index_directory             TEXT,                                                                                            -- INDEX DIRECTORY, where written
  autoextend_size             TEXT,                                                                                            -- AUTOEXTEND_SIZE, where written (8.0.23 and later)
  engine_attribute            TEXT,                                                                                            -- ENGINE_ATTRIBUTE, a JSON text, where written (8.0.21 and later)
  secondary_engine            TEXT,                                                                                            -- SECONDARY_ENGINE, where written
  secondary_engine_attribute  TEXT,                                                                                            -- SECONDARY_ENGINE_ATTRIBUTE, where written
  insert_method               TEXT CHECK (insert_method IN ('NO', 'FIRST', 'LAST')),                                           -- a MERGE table's INSERT_METHOD; its tables are its dependencies, in order
  connection                  TEXT,                                                                                            -- a FEDERATED table's CONNECTION through a server: its name, and the remote table where named (server/table); a connection string is never kept, it may carry a password
  flavor_options              JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  CHECK (insert_method IS NULL OR engine = 'MRG_MYISAM'),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
