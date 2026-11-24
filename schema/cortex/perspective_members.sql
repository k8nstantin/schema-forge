-- cortex.perspective_members: the tables and columns a custom perspective shows, in order. Owner: cortex.
CREATE TABLE cortex.perspective_members (
  id           TEXT    NOT NULL PRIMARY KEY,                                                   -- <perspective>.member<n>, n given once from id_counters and never reused: p_billing_review.member1
  perspective  TEXT    NOT NULL REFERENCES cortex.custom_perspectives (id) ON DELETE CASCADE,  -- the perspective
  object       TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,              -- the table or view shown
  "column"     TEXT    REFERENCES cortex.columns (id) ON DELETE CASCADE,                       -- one of its columns, shown alone; NULL for the whole object
  position     NUMERIC NOT NULL CHECK (position > 0),                                          -- its place in the perspective; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  colour       TEXT    CHECK (colour ~ '^#[0-9a-f]{6}$'),                                      -- its own colour, as #rrggbb; NULL to follow the perspective's colour_by
  UNIQUE (perspective, position),
  CHECK (substr(id, 1, length(perspective) + 7) = perspective || '.member' AND substr(id, length(perspective) + 8) ~ '^[1-9][0-9]*$')
);
CREATE UNIQUE INDEX perspective_members_once ON cortex.perspective_members (perspective, object, coalesce("column", '')); -- an object, or one of its columns, is in a perspective once

COMMENT ON TABLE cortex.perspective_members IS 'the tables and columns a custom perspective shows, in order.';
COMMENT ON COLUMN cortex.perspective_members.id IS '<perspective>.member<n>, n given once from id_counters and never reused: p_billing_review.member1';
COMMENT ON COLUMN cortex.perspective_members.perspective IS 'the perspective';
COMMENT ON COLUMN cortex.perspective_members.object IS 'the table or view shown';
COMMENT ON COLUMN cortex.perspective_members."column" IS 'one of its columns, shown alone; NULL for the whole object';
COMMENT ON COLUMN cortex.perspective_members.position IS 'its place in the perspective; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.perspective_members.colour IS 'its own colour, as #rrggbb; NULL to follow the perspective''s colour_by';
