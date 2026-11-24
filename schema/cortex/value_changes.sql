-- cortex.value_changes: every column value a row change set or cleared: for an insert every column, for a delete every column, for an update the columns that changed. Owner: cortex.
CREATE TABLE cortex.value_changes (
  id           TEXT  NOT NULL PRIMARY KEY,                                      -- <row change>.<column>
  row_change   TEXT  NOT NULL REFERENCES cortex.row_changes (id),               -- the row change
  column_name  TEXT  NOT NULL CHECK (column_name ~ '^[a-z0-9_]+$'),             -- the column
  before       JSONB,                                                           -- its value before; NULL for an insert, and for a value that was null
  after        JSONB,                                                           -- its value after; NULL for a delete, and for a value that is null
  UNIQUE (row_change, column_name),
  CHECK (id = row_change || '.' || column_name)
);

COMMENT ON TABLE cortex.value_changes IS 'every column value a row change set or cleared: for an insert every column, for a delete every column, for an update the columns that changed.';
COMMENT ON COLUMN cortex.value_changes.id IS '<row change>.<column>';
COMMENT ON COLUMN cortex.value_changes.row_change IS 'the row change';
COMMENT ON COLUMN cortex.value_changes.column_name IS 'the column';
COMMENT ON COLUMN cortex.value_changes.before IS 'its value before; NULL for an insert, and for a value that was null';
COMMENT ON COLUMN cortex.value_changes.after IS 'its value after; NULL for a delete, and for a value that is null';
