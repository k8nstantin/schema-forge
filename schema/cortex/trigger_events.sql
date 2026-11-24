-- trigger_events: the changes a trigger fires on, in order. Owner: cortex.
CREATE TABLE trigger_events (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <trigger>.on<position>: o_orders_touch.on1
  "trigger" TEXT    NOT NULL REFERENCES triggers (id) ON DELETE CASCADE,       -- the trigger
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the trigger's changes
  change    TEXT    NOT NULL CHECK (change IN ('insert', 'update', 'delete', 'truncate')),  -- the change it fires on
  UNIQUE ("trigger", position),
  UNIQUE ("trigger", change),
  CHECK (id = "trigger" || '.on' || position)
) STRICT;
