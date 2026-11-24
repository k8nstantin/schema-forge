-- objects: everything a namespace holds: tables, views, routines, triggers, whatever kinds the engine has. Owner: cortex.
CREATE TABLE objects (
  id         TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'o_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (o_orders), kept when the name changes
  kind       TEXT    NOT NULL REFERENCES kinds (id),                         -- one of the engine's kinds: no other is accepted
  namespace  TEXT    NOT NULL REFERENCES namespaces (id) ON DELETE CASCADE,   -- the namespace that holds it
  name       TEXT    NOT NULL CHECK (length(name) >= 1),                      -- orders
  position   INTEGER NOT NULL UNIQUE CHECK (position >= 1),                   -- its place among the objects, in the order they were made or read
  comment    TEXT,                                                            -- what it holds, in a sentence or two: written into its SQL
  notes      TEXT,                                                            -- longer notes for people and the agent: never written into SQL
  area       TEXT    REFERENCES areas (id) ON DELETE SET NULL,                -- the area it belongs to; NULL for none
  UNIQUE (namespace, kind, name)
) STRICT;
