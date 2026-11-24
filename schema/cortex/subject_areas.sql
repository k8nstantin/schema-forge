-- cortex.subject_areas: groups of objects by subject (billing, catalog), across namespaces. Owner: cortex.
CREATE TABLE cortex.subject_areas (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^a_[a-z0-9_]*$' AND length(id) <= 128),  -- the model's id (a_billing)
  name      TEXT    NOT NULL UNIQUE CHECK (length(name) >= 1),                                 -- billing
  colour    TEXT,                                                                              -- its colour on the canvas, as the model holds it; NULL for the canvas's choice
  position  NUMERIC NOT NULL UNIQUE CHECK (position > 0)                                       -- its place among the areas; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
);

COMMENT ON TABLE cortex.subject_areas IS 'groups of objects by subject (billing, catalog), across namespaces.';
COMMENT ON COLUMN cortex.subject_areas.id IS 'the model''s id (a_billing)';
COMMENT ON COLUMN cortex.subject_areas.name IS 'billing';
COMMENT ON COLUMN cortex.subject_areas.colour IS 'its colour on the canvas, as the model holds it; NULL for the canvas''s choice';
COMMENT ON COLUMN cortex.subject_areas.position IS 'its place among the areas; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
