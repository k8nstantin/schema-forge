-- cortex.custom_perspectives: a perspective someone saved: their own choice of tables and columns, grouped and coloured their way. Owner: cortex.
-- Part of the design (decision canvas-state): shareable, and the agent may make one; its members are in perspective_members.
CREATE TABLE cortex.custom_perspectives (
  id         TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^p_[a-z0-9_]*$' AND length(id) <= 128),  -- the perspective's id (p_billing_review), kept when it is renamed
  name       TEXT    NOT NULL UNIQUE CHECK (length(name) >= 1),                                 -- as people call it (Billing review)
  position   NUMERIC NOT NULL UNIQUE CHECK (position > 0),                                      -- its place among the perspectives; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  group_by   TEXT    NOT NULL DEFAULT 'family' CHECK (group_by IN ('namespace', 'family', 'area', 'none')),  -- how its tables are grouped
  colour_by  TEXT    NOT NULL DEFAULT 'family' CHECK (colour_by IN ('namespace', 'family', 'area', 'none')),  -- what its colours follow, unless a member sets its own
  comment    TEXT,                                                                              -- what it is for; NULL for none
  made_by    TEXT    NOT NULL CHECK (length(made_by) >= 1)                                      -- who made it: a person's name or the agent's label
);

COMMENT ON TABLE cortex.custom_perspectives IS 'a perspective someone saved: their own choice of tables and columns, grouped and coloured their way. Part of the design (decision canvas-state): shareable, and the agent may make one; its members are in perspective_members.';
COMMENT ON COLUMN cortex.custom_perspectives.id IS 'the perspective''s id (p_billing_review), kept when it is renamed';
COMMENT ON COLUMN cortex.custom_perspectives.name IS 'as people call it (Billing review)';
COMMENT ON COLUMN cortex.custom_perspectives.position IS 'its place among the perspectives; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.custom_perspectives.group_by IS 'how its tables are grouped';
COMMENT ON COLUMN cortex.custom_perspectives.colour_by IS 'what its colours follow, unless a member sets its own';
COMMENT ON COLUMN cortex.custom_perspectives.comment IS 'what it is for; NULL for none';
COMMENT ON COLUMN cortex.custom_perspectives.made_by IS 'who made it: a person''s name or the agent''s label';
