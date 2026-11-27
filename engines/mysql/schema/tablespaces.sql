-- engine_mysql.tablespaces: a general tablespace of the server (CREATE TABLESPACE): its engine, file and options; the tables in it name it.
CREATE TABLE engine_mysql.tablespaces (
  id                UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design            UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  engine            TEXT NOT NULL DEFAULT 'InnoDB',                                                                  -- its storage engine
  file_name         TEXT NOT NULL CHECK (length(file_name) >= 1),                                                    -- ADD DATAFILE, as written (ts1.ibd)
  file_block_size   INTEGER CHECK (file_block_size > 0),                                                             -- FILE_BLOCK_SIZE, where written
  encryption        BOOLEAN,                                                                                         -- ENCRYPTION, where written
  autoextend_size   TEXT,                                                                                            -- AUTOEXTEND_SIZE, where written (8.0.23 and later)
  engine_attribute  TEXT,                                                                                            -- ENGINE_ATTRIBUTE, where written
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
