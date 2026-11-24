-- value_changes: every column value a row change set or cleared: for an insert every column, for a delete every column, for an update the columns that changed. Owner: cortex.
CREATE TABLE value_changes (
  id           TEXT  NOT NULL PRIMARY KEY,                                     -- <row change>.<column>
  row_change   TEXT  NOT NULL REFERENCES row_changes (id),                     -- the row change
  column_name  TEXT  NOT NULL CHECK (column_name NOT GLOB '*[^a-z0-9_]*'),     -- the column
  before       ANY,                                                            -- its value before; NULL for an insert, and for a value that was null
  after        ANY,                                                            -- its value after; NULL for a delete, and for a value that is null
  UNIQUE (row_change, column_name),
  CHECK (id = row_change || '.' || column_name)
) STRICT;
