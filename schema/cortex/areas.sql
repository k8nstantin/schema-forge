-- areas: groups of objects by subject (billing, catalog), across namespaces. Owner: cortex.
CREATE TABLE areas (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'a_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (a_billing)
  name      TEXT    NOT NULL UNIQUE CHECK (length(name) >= 1),                -- billing
  colour    TEXT    CHECK (colour GLOB '#[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'),  -- its colour on the canvas, #rrggbb; NULL for the canvas's choice
  position  INTEGER NOT NULL UNIQUE CHECK (position >= 1)                     -- its place among the areas
) STRICT;
