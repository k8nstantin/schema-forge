-- engine_mysql.columns: what MySQL says of a column beyond the cortex (its type with UNSIGNED and ZEROFILL is the cortex's type, as COLUMN_TYPE writes it).
CREATE TABLE engine_mysql.columns (
  id                          UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex column
  design                      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  character_set               TEXT,                                                                                            -- its character set where written; NULL for its table's
  default_is_expression       BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when its default is an expression written in parentheses or CURRENT_TIMESTAMP, not a literal
  on_update                   TEXT,                                                                                            -- ON UPDATE, as written (CURRENT_TIMESTAMP(3)); NULL for none
  auto_increment              BOOLEAN NOT NULL DEFAULT false,                                                                  -- true for the column the server numbers
  invisible                   BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when INVISIBLE (8.0.23 and later)
  srid                        INTEGER,                                                                                         -- SRID of a spatial column, where written (8.0 and later)
  column_format               TEXT CHECK (column_format IN ('FIXED', 'DYNAMIC', 'DEFAULT', 'COMPRESSED')),                    -- COLUMN_FORMAT, where written (COMPRESSED is Percona's)
  storage                     TEXT CHECK (storage IN ('DISK', 'MEMORY')),                                                      -- STORAGE, where written
  compression_dictionary      UUID,                                                                                            -- Percona: the dictionary a COMPRESSED column is compressed with; NULL for none
  engine_attribute            TEXT,                                                                                            -- ENGINE_ATTRIBUTE, a JSON text, where written
  secondary_engine_attribute  TEXT,                                                                                            -- SECONDARY_ENGINE_ATTRIBUTE, where written
  flavor_options              JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  CHECK (compression_dictionary IS NULL OR column_format = 'COMPRESSED'),
  FOREIGN KEY (design, id) REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, compression_dictionary) REFERENCES cortex.objects (design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX columns_compression_dictionary ON engine_mysql.columns (design, compression_dictionary);
