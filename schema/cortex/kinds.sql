-- kinds: the kinds of object this schema's engine has, as the engine declares them. Owner: cortex.
-- Written from the engine's declaration when the file is made and when the engine's version of the file changes;
-- an object of a kind not here is refused by objects.kind.
CREATE TABLE kinds (
  id          TEXT    NOT NULL PRIMARY KEY CHECK (id NOT GLOB '*[^a-z0-9_]*'),  -- as an object names its kind (table, view, record)
  name        TEXT    NOT NULL,                                                -- as people say it (Table)
  table_like  INTEGER NOT NULL CHECK (table_like IN (0, 1)),                   -- 1 when the kind holds keys: the perspectives draw it as a table
  position    INTEGER NOT NULL UNIQUE CHECK (position >= 1)                    -- its place in the engine's declaration, for listing in the engine's order
) STRICT;
