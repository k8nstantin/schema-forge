-- areas: groups of objects by subject (billing, catalog), across namespaces. Owner: cortex.
CREATE TABLE areas (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'a_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (a_billing)
  name      TEXT    NOT NULL UNIQUE CHECK (length(name) >= 1),                -- billing
  colour    TEXT,                                                              -- its colour on the canvas, as the model holds it; NULL for the canvas's choice
  position  INTEGER NOT NULL UNIQUE CHECK (position >= 1)                     -- its place among the areas
) STRICT;
