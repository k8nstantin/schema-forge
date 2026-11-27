-- cortex.row_changes: the log: every row an operation inserted, updated or deleted in any table of the model or a plugin, with its values before and after; written only by the trigger cortex.log_row, never by a person, the app or the agent.
CREATE TABLE cortex.row_changes (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row: the log reads in this order
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  operation  UUID NOT NULL,                                                                                   -- the operation that changed the row
  tab        TEXT NOT NULL CHECK (tab ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),                                -- the table changed, with its namespace (engine_mysql.tables)
  row_id     UUID NOT NULL,                                                                                   -- the row's id
  action     TEXT NOT NULL CHECK (action IN ('insert', 'update', 'delete')),                                  -- what was done to it
  before     JSONB,                                                                                           -- the row before, every column; NULL for an insert
  after      JSONB,                                                                                           -- the row after, every column; NULL for a delete
  UNIQUE (design, id),
  CHECK ((before IS NULL) = (action = 'insert') AND (after IS NULL) = (action = 'delete')),
  FOREIGN KEY (design, operation) REFERENCES cortex.operations (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX row_changes_operation ON cortex.row_changes (design, operation);
CREATE INDEX row_changes_row ON cortex.row_changes (design, row_id);
