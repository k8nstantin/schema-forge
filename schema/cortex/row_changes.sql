-- row_changes: every row an operation inserted, updated or deleted, in any table of the file, in the order it changed them. Owner: cortex.
-- With value_changes, the exact record of what the operation did; its inverse is worked out from this record, never written by hand.
CREATE TABLE row_changes (
  id          TEXT    NOT NULL PRIMARY KEY,                                    -- <operation>.<position>
  operation   TEXT    NOT NULL REFERENCES operations (id),                     -- the operation
  position    INTEGER NOT NULL CHECK (position >= 1),                          -- the order the rows changed in
  table_name  TEXT    NOT NULL CHECK (table_name NOT GLOB '*[^a-z0-9_]*'),     -- the table, cortex or engine (objects, mysql__table_options)
  row_id      TEXT    NOT NULL,                                                -- the row's id, its primary key
  action      TEXT    NOT NULL CHECK (action IN ('insert', 'update', 'delete')),  -- what happened to the row
  UNIQUE (operation, position),
  CHECK (id = operation || '.' || position)
) STRICT;
