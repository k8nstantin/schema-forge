-- queries: a view's query, exactly as written in the engine's SQL. Owner: cortex.
CREATE TABLE queries (
  id    TEXT  NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the view
  text  TEXT  NOT NULL CHECK (length(text) >= 1)                               -- the query
) STRICT;
