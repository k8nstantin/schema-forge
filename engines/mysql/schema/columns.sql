-- engine_mysql.columns: what MySQL says of a column beyond the cortex; a row only where it says something. Owner: mysql.
CREATE TABLE engine_mysql.columns (
  id         UUID NOT NULL PRIMARY KEY,                                                                     -- the column
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  on_update  TEXT,                                                                                          -- what it becomes whenever its row changes (CURRENT_TIMESTAMP); NULL for none
  srid       BIGINT CHECK (srid >= 0),                                                                      -- the spatial reference system of its shapes; NULL for none
  invisible  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when SELECT * leaves it out (8.0.23 and later)
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.columns IS 'what MySQL says of a column beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_mysql.columns.id IS 'the column';
COMMENT ON COLUMN engine_mysql.columns.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.columns.on_update IS 'what it becomes whenever its row changes (CURRENT_TIMESTAMP); NULL for none';
COMMENT ON COLUMN engine_mysql.columns.srid IS 'the spatial reference system of its shapes; NULL for none';
COMMENT ON COLUMN engine_mysql.columns.invisible IS 'true when SELECT * leaves it out (8.0.23 and later)';
