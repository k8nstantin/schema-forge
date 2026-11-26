-- cortex.row_changes: the log: every row an operation inserted, updated or deleted, in any table of the cortex and the engines, with its values before and after; appended, never edited. Undo applies them backwards, redo forwards. Owner: cortex.
CREATE TABLE cortex.row_changes (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made by the database as the row changed (uuidv7(), monotonic within a session): its order is the order the rows changed in
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  operation   UUID NOT NULL,                                                                                 -- the operation
  table_name  TEXT NOT NULL CHECK (table_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),                       -- the table, with its namespace (cortex.objects, engine_mysql.tables)
  row_id      UUID NOT NULL,                                                                                 -- the row's id
  action      TEXT NOT NULL CHECK (action IN ('insert', 'update', 'delete')),                                -- what happened to the row
  before      JSONB,                                                                                         -- for an update, the values it changed as they were; for a delete, the whole row; NULL for an insert
  after       JSONB,                                                                                         -- for an update, the values it changed as they are; for an insert, the whole row; NULL for a delete
  CHECK ((action = 'insert') = (before IS NULL)),
  CHECK ((action = 'delete') = (after IS NULL)),
  UNIQUE (design, id),
  FOREIGN KEY (design, operation) REFERENCES cortex.operations (design, id)
);

CREATE INDEX row_changes_operation ON cortex.row_changes (design, operation, id);

COMMENT ON TABLE cortex.row_changes IS 'the log: every row an operation inserted, updated or deleted, in any table of the cortex and the engines, with its values before and after; appended, never edited. Undo applies them backwards, redo forwards.';
COMMENT ON COLUMN cortex.row_changes.id IS 'UUIDv7, made by the database as the row changed (uuidv7(), monotonic within a session): its order is the order the rows changed in';
COMMENT ON COLUMN cortex.row_changes.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.row_changes.operation IS 'the operation';
COMMENT ON COLUMN cortex.row_changes.table_name IS 'the table, with its namespace (cortex.objects, engine_mysql.tables)';
COMMENT ON COLUMN cortex.row_changes.row_id IS 'the row''s id';
COMMENT ON COLUMN cortex.row_changes.action IS 'what happened to the row';
COMMENT ON COLUMN cortex.row_changes.before IS 'for an update, the values it changed as they were; for a delete, the whole row; NULL for an insert';
COMMENT ON COLUMN cortex.row_changes.after IS 'for an update, the values it changed as they are; for an insert, the whole row; NULL for a delete';
