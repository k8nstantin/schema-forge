-- cortex.view_queries: a view's query, exactly as written in the engine's SQL. Owner: cortex.
CREATE TABLE cortex.view_queries (
  id    TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the view
  text  TEXT NOT NULL CHECK (length(text) >= 1)                                      -- the query
);

COMMENT ON TABLE cortex.view_queries IS 'a view''s query, exactly as written in the engine''s SQL.';
COMMENT ON COLUMN cortex.view_queries.id IS 'the view';
COMMENT ON COLUMN cortex.view_queries.text IS 'the query';
