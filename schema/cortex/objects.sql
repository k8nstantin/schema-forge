-- cortex.objects: everything a namespace holds: tables, views, routines, triggers, whatever kinds the engine has. Owner: cortex.
CREATE TABLE cortex.objects (
  id         TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^o_[a-z0-9_]*$' AND length(id) <= 128),  -- the model's id (o_orders), kept when the name changes
  kind       TEXT    NOT NULL REFERENCES cortex.object_kinds (id),                              -- one of the engine's kinds: no other is accepted
  namespace  TEXT    NOT NULL REFERENCES cortex.namespaces (id) ON DELETE CASCADE,              -- the namespace that holds it
  name       TEXT    NOT NULL CHECK (length(name) >= 1),                                        -- orders
  position   NUMERIC NOT NULL UNIQUE CHECK (position > 0),                                      -- its place among the objects, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  comment    TEXT,                                                                              -- what it holds, in a sentence or two: written into its SQL
  notes      TEXT,                                                                              -- longer notes for people and the agent: never written into SQL
  area       TEXT    REFERENCES cortex.subject_areas (id) ON DELETE SET NULL,                   -- the area it belongs to; NULL for none
  UNIQUE (namespace, name)
);

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds: tables, views, routines, triggers, whatever kinds the engine has.';
COMMENT ON COLUMN cortex.objects.id IS 'the model''s id (o_orders), kept when the name changes';
COMMENT ON COLUMN cortex.objects.kind IS 'one of the engine''s kinds: no other is accepted';
COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it';
COMMENT ON COLUMN cortex.objects.name IS 'orders';
COMMENT ON COLUMN cortex.objects.position IS 'its place among the objects, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';
COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';
COMMENT ON COLUMN cortex.objects.area IS 'the area it belongs to; NULL for none';
