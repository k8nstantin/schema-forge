-- mysql__column_options: what MySQL says of a column beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__column_options (
  id                          TEXT     NOT NULL PRIMARY KEY REFERENCES columns (id) ON DELETE CASCADE,  -- the column
  charset                     TEXT,    -- its character set; NULL when not written
  collation                   TEXT,    -- its collation; NULL when not written
  "binary"                    INTEGER CHECK ("binary" IN (0, 1)),          -- 1 when it uses its character set's binary collation (BINARY, deprecated); NULL when not written
  on_update                   TEXT,    -- what it becomes whenever its row changes (ON UPDATE CURRENT_TIMESTAMP); NULL for none
  srid                        INTEGER CHECK (srid >= 0),                   -- the spatial reference system of its shapes; NULL for none
  invisible                   INTEGER CHECK (invisible IN (0, 1)),         -- 1 when SELECT * leaves it out; NULL when not written
  column_format               TEXT CHECK (column_format IN ('FIXED', 'DYNAMIC', 'DEFAULT')),  -- how it is stored (NDB); NULL when not written
  storage                     TEXT CHECK (storage IN ('DISK', 'MEMORY')),  -- where it is stored (NDB); NULL when not written
  engine_attribute            TEXT,    -- what its storage engine is told about it; NULL when not written
  secondary_engine_attribute  TEXT     -- what its secondary engine is told about it; NULL when not written
) STRICT;
