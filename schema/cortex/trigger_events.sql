-- cortex.trigger_events: the changes a trigger fires on, in order. Owner: cortex.
CREATE TABLE cortex.trigger_events (
  id         TEXT    NOT NULL PRIMARY KEY,                                                   -- <trigger>.on<n>, n given once from id_counters and never reused: o_orders_touch.on1
  "trigger"  TEXT    NOT NULL REFERENCES cortex.triggers (id) ON DELETE CASCADE,             -- the trigger
  position   NUMERIC NOT NULL CHECK (position > 0),                                          -- its place among the trigger's changes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  change     TEXT    NOT NULL CHECK (change IN ('insert', 'update', 'delete', 'truncate')),  -- the change it fires on
  UNIQUE ("trigger", position),
  UNIQUE ("trigger", change),
  CHECK (substr(id, 1, length("trigger") + 3) = "trigger" || '.on' AND substr(id, length("trigger") + 4) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.trigger_events IS 'the changes a trigger fires on, in order.';
COMMENT ON COLUMN cortex.trigger_events.id IS '<trigger>.on<n>, n given once from id_counters and never reused: o_orders_touch.on1';
COMMENT ON COLUMN cortex.trigger_events."trigger" IS 'the trigger';
COMMENT ON COLUMN cortex.trigger_events.position IS 'its place among the trigger''s changes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.trigger_events.change IS 'the change it fires on';
