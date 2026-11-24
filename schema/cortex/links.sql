-- links: a link from columns of one object to columns of another: a foreign key, or a link the design only draws. Owner: cortex.
CREATE TABLE links (
  id                  TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'l_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (l_orders_customer)
  name                TEXT,                                                    -- its constraint name; NULL for none
  from_object         TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,  -- the object that refers
  to_object           TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,  -- the object referred to
  position            INTEGER NOT NULL UNIQUE CHECK (position >= 1),           -- its place among the links
  enforced            INTEGER NOT NULL DEFAULT 1 CHECK (enforced IN (0, 1)),   -- 1 when the database enforces it (a foreign key); 0 when the design only draws it
  on_delete           TEXT    CHECK (on_delete IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),  -- what happens when the row referred to is deleted; NULL for the engine's default
  on_update           TEXT    CHECK (on_update IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),  -- what happens when its key changes; NULL for the engine's default
  match_kind          TEXT,                                                    -- how a key of several columns with some null matches, in the engine's words (full, simple); NULL for the engine's default
  "deferrable"        INTEGER NOT NULL DEFAULT 0 CHECK ("deferrable" IN (0, 1)), -- 1 when it may be checked at the end of a transaction
  initially_deferred  INTEGER CHECK (initially_deferred IN (0, 1)),            -- for a deferrable link: 1 when it is checked at the end unless said otherwise
  CHECK (("deferrable" = 1) = (initially_deferred IS NOT NULL))
) STRICT;
