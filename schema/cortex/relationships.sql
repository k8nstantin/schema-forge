-- cortex.relationships: a relationship from columns of one object to columns of another: a foreign key, or one the design only draws. Owner: cortex.
CREATE TABLE cortex.relationships (
  id                  TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^l_[a-z0-9_]*$' AND length(id) <= 128),  -- the model's id (l_orders_customer)
  name                TEXT,                                                               -- its constraint name; NULL for none
  from_object         TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object that refers
  to_object           TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object referred to
  position            NUMERIC NOT NULL UNIQUE CHECK (position > 0),                       -- its place among the relationships; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  enforced            BOOLEAN NOT NULL DEFAULT true,                                      -- true when the database enforces it (a foreign key); false when the design only draws it
  on_delete           TEXT    CHECK (on_delete IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),  -- what happens when the row referred to is deleted; NULL for the engine's default
  on_update           TEXT    CHECK (on_update IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),  -- what happens when its key changes; NULL for the engine's default
  match_kind          TEXT,                                                               -- how a key of several columns with some null matches, in the engine's words (full, simple); NULL for the engine's default
  "deferrable"        BOOLEAN NOT NULL DEFAULT false,                                     -- true when it may be checked at the end of a transaction
  initially_deferred  BOOLEAN,                                                            -- for a deferrable relationship: true when it is checked at the end unless said otherwise
  CHECK ("deferrable" = (initially_deferred IS NOT NULL))
);

COMMENT ON TABLE cortex.relationships IS 'a relationship from columns of one object to columns of another: a foreign key, or one the design only draws.';
COMMENT ON COLUMN cortex.relationships.id IS 'the model''s id (l_orders_customer)';
COMMENT ON COLUMN cortex.relationships.name IS 'its constraint name; NULL for none';
COMMENT ON COLUMN cortex.relationships.from_object IS 'the object that refers';
COMMENT ON COLUMN cortex.relationships.to_object IS 'the object referred to';
COMMENT ON COLUMN cortex.relationships.position IS 'its place among the relationships; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.relationships.enforced IS 'true when the database enforces it (a foreign key); false when the design only draws it';
COMMENT ON COLUMN cortex.relationships.on_delete IS 'what happens when the row referred to is deleted; NULL for the engine''s default';
COMMENT ON COLUMN cortex.relationships.on_update IS 'what happens when its key changes; NULL for the engine''s default';
COMMENT ON COLUMN cortex.relationships.match_kind IS 'how a key of several columns with some null matches, in the engine''s words (full, simple); NULL for the engine''s default';
COMMENT ON COLUMN cortex.relationships."deferrable" IS 'true when it may be checked at the end of a transaction';
COMMENT ON COLUMN cortex.relationships.initially_deferred IS 'for a deferrable relationship: true when it is checked at the end unless said otherwise';
