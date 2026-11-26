-- engine_postgresql.trigger_columns: the columns a trigger fires on when they are updated (UPDATE OF ...), in order. Owner: postgresql.
CREATE TABLE engine_postgresql.trigger_columns (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  trigger   UUID NOT NULL,                                                                                 -- the trigger
  "column"  UUID NOT NULL,                                                                                 -- a column of its table it fires on
  position  NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place in UPDATE OF; an order key: one put between two takes their midpoint, so nothing is renumbered
  UNIQUE (trigger, "column") DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (trigger, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, trigger) REFERENCES cortex.triggers (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX trigger_columns_trigger ON engine_postgresql.trigger_columns (design, trigger);
CREATE INDEX trigger_columns_column ON engine_postgresql.trigger_columns (design, "column");

COMMENT ON TABLE engine_postgresql.trigger_columns IS 'the columns a trigger fires on when they are updated (UPDATE OF ...), in order.';
COMMENT ON COLUMN engine_postgresql.trigger_columns.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.trigger_columns.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.trigger_columns.trigger IS 'the trigger';
COMMENT ON COLUMN engine_postgresql.trigger_columns."column" IS 'a column of its table it fires on';
COMMENT ON COLUMN engine_postgresql.trigger_columns.position IS 'its place in UPDATE OF; an order key: one put between two takes their midpoint, so nothing is renumbered';
