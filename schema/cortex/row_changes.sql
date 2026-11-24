-- cortex.row_changes: every row an operation inserted, updated or deleted, in any table of the database, in the order it changed them. Owner: cortex.
-- With value_changes, the exact record of what the operation did; its inverse is worked out from this record, never written by hand.
CREATE TABLE cortex.row_changes (
  id          TEXT    NOT NULL PRIMARY KEY,                                                -- <operation>.<n>, n its place in the operation (the log is never reordered)
  operation   UUID    NOT NULL REFERENCES cortex.operations (id),                          -- the operation
  position    INTEGER NOT NULL CHECK (position >= 1),                                      -- the order the rows changed in
  table_name  TEXT    NOT NULL CHECK (table_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- the table, cortex or engine with its namespace (cortex.objects, engine_mysql.table_options)
  row_id      TEXT    NOT NULL,                                                            -- the row's id, its primary key
  action      TEXT    NOT NULL CHECK (action IN ('insert', 'update', 'delete')),           -- what happened to the row
  UNIQUE (operation, position),
  CHECK (left(id, 37) = operation::text || '.' AND substr(id, 38) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.row_changes IS 'every row an operation inserted, updated or deleted, in any table of the database, in the order it changed them. With value_changes, the exact record of what the operation did; its inverse is worked out from this record, never written by hand.';
COMMENT ON COLUMN cortex.row_changes.id IS '<operation>.<n>, n its place in the operation (the log is never reordered)';
COMMENT ON COLUMN cortex.row_changes.operation IS 'the operation';
COMMENT ON COLUMN cortex.row_changes.position IS 'the order the rows changed in';
COMMENT ON COLUMN cortex.row_changes.table_name IS 'the table, cortex or engine with its namespace (cortex.objects, engine_mysql.table_options)';
COMMENT ON COLUMN cortex.row_changes.row_id IS 'the row''s id, its primary key';
COMMENT ON COLUMN cortex.row_changes.action IS 'what happened to the row';
