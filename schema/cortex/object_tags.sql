-- cortex.object_tags: the tags of an object (scd2, pii), in order. Owner: cortex.
CREATE TABLE cortex.object_tags (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.tag<n>, n given once from id_counters and never reused: o_orders.tag1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object tagged
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the object's tags; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  tag       TEXT    NOT NULL CHECK (length(tag) >= 1),                          -- the tag
  UNIQUE (object, position),
  UNIQUE (object, tag),
  CHECK (substr(id, 1, length(object) + 4) = object || '.tag' AND substr(id, length(object) + 5) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.object_tags IS 'the tags of an object (scd2, pii), in order.';
COMMENT ON COLUMN cortex.object_tags.id IS '<object>.tag<n>, n given once from id_counters and never reused: o_orders.tag1';
COMMENT ON COLUMN cortex.object_tags.object IS 'the object tagged';
COMMENT ON COLUMN cortex.object_tags.position IS 'its place among the object''s tags; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.object_tags.tag IS 'the tag';
