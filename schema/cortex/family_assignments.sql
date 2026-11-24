-- cortex.family_assignments: an object put in a family by hand, overriding the family worked out from its name. Owner: cortex.
-- Shape 1 of the owner template: at most one row per object, its id the object's. An object with no row is in the family its name gives.
CREATE TABLE cortex.family_assignments (
  id      TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object
  family  TEXT NOT NULL CHECK (length(family) >= 1)                                    -- the family it belongs to, as the canvas names families (billing)
);

COMMENT ON TABLE cortex.family_assignments IS 'an object put in a family by hand, overriding the family worked out from its name. Shape 1 of the owner template: at most one row per object, its id the object''s. An object with no row is in the family its name gives.';
COMMENT ON COLUMN cortex.family_assignments.id IS 'the object';
COMMENT ON COLUMN cortex.family_assignments.family IS 'the family it belongs to, as the canvas names families (billing)';
