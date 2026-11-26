-- engine_mysql.tables: the options of a MySQL table, each typed, each only where its statement writes it. Owner: mysql.
CREATE TABLE engine_mysql.tables (
  id                  BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the table
  engine              TEXT NOT NULL,                                                                                               -- its storage engine, as SHOW CREATE writes it (InnoDB, MyISAM, MRG_MyISAM)
  "collation"         TEXT NOT NULL,                                                                                               -- its default collation; its character set is the collation's
  auto_increment      BIGINT CHECK (auto_increment >= 1),                                                                          -- the next number its AUTO_INCREMENT column gives, from SHOW CREATE (TABLES caches it on 8.0 and later); NULL when not written
  row_format          TEXT,                                                                                                        -- ROW_FORMAT, where written
  avg_row_length      BIGINT,                                                                                                      -- AVG_ROW_LENGTH, where written
  min_rows            BIGINT,                                                                                                      -- MIN_ROWS, where written
  max_rows            BIGINT,                                                                                                      -- MAX_ROWS, where written
  pack_keys           TEXT,                                                                                                        -- PACK_KEYS, where written
  checksum            TEXT,                                                                                                        -- CHECKSUM, where written
  delay_key_write     TEXT,                                                                                                        -- DELAY_KEY_WRITE, where written
  key_block_size      INTEGER,                                                                                                     -- KEY_BLOCK_SIZE, where written
  stats_persistent    TEXT,                                                                                                        -- STATS_PERSISTENT, where written
  stats_auto_recalc   TEXT,                                                                                                        -- STATS_AUTO_RECALC, where written
  stats_sample_pages  TEXT,                                                                                                        -- STATS_SAMPLE_PAGES, where written
  compression         TEXT,                                                                                                        -- COMPRESSION, where written
  encryption          TEXT,                                                                                                        -- ENCRYPTION, where written
  tablespace          TEXT,                                                                                                        -- the tablespace it is stored in, where written
  insert_method       TEXT,                                                                                                        -- a MERGE table's INSERT_METHOD; its tables are dependencies, in order
  CHECK (insert_method IS NULL OR engine = 'MRG_MyISAM')
);

COMMENT ON TABLE engine_mysql.tables IS 'the options of a MySQL table, each typed, each only where its statement writes it.';
COMMENT ON COLUMN engine_mysql.tables.id IS 'the table';
COMMENT ON COLUMN engine_mysql.tables.engine IS 'its storage engine, as SHOW CREATE writes it (InnoDB, MyISAM, MRG_MyISAM)';
COMMENT ON COLUMN engine_mysql.tables."collation" IS 'its default collation; its character set is the collation''s';
COMMENT ON COLUMN engine_mysql.tables.auto_increment IS 'the next number its AUTO_INCREMENT column gives, from SHOW CREATE (TABLES caches it on 8.0 and later); NULL when not written';
COMMENT ON COLUMN engine_mysql.tables.row_format IS 'ROW_FORMAT, where written';
COMMENT ON COLUMN engine_mysql.tables.avg_row_length IS 'AVG_ROW_LENGTH, where written';
COMMENT ON COLUMN engine_mysql.tables.min_rows IS 'MIN_ROWS, where written';
COMMENT ON COLUMN engine_mysql.tables.max_rows IS 'MAX_ROWS, where written';
COMMENT ON COLUMN engine_mysql.tables.pack_keys IS 'PACK_KEYS, where written';
COMMENT ON COLUMN engine_mysql.tables.checksum IS 'CHECKSUM, where written';
COMMENT ON COLUMN engine_mysql.tables.delay_key_write IS 'DELAY_KEY_WRITE, where written';
COMMENT ON COLUMN engine_mysql.tables.key_block_size IS 'KEY_BLOCK_SIZE, where written';
COMMENT ON COLUMN engine_mysql.tables.stats_persistent IS 'STATS_PERSISTENT, where written';
COMMENT ON COLUMN engine_mysql.tables.stats_auto_recalc IS 'STATS_AUTO_RECALC, where written';
COMMENT ON COLUMN engine_mysql.tables.stats_sample_pages IS 'STATS_SAMPLE_PAGES, where written';
COMMENT ON COLUMN engine_mysql.tables.compression IS 'COMPRESSION, where written';
COMMENT ON COLUMN engine_mysql.tables.encryption IS 'ENCRYPTION, where written';
COMMENT ON COLUMN engine_mysql.tables.tablespace IS 'the tablespace it is stored in, where written';
COMMENT ON COLUMN engine_mysql.tables.insert_method IS 'a MERGE table''s INSERT_METHOD; its tables are dependencies, in order';
