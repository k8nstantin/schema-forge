-- cortex.namespaces: the levels that hold objects, nested under another or at the top. Owner: cortex.
-- What the engine calls one (a database, a schema, a shelf) is the engine's word, never stored here.
CREATE TABLE cortex.namespaces (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^n_[a-z0-9_]*$' AND length(id) <= 128),  -- the model's id (n_sales), kept when the name changes
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                                        -- sales
  parent    TEXT    REFERENCES cortex.namespaces (id) ON DELETE CASCADE,                       -- the namespace it sits in; NULL at the top
  position  NUMERIC NOT NULL CHECK (position > 0),                                             -- its place among the namespaces, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  comment   TEXT,                                                                              -- what it holds
  UNIQUE (position)
);
CREATE UNIQUE INDEX namespaces_name ON cortex.namespaces (coalesce(parent, ''), name);  -- two namespaces beside each other never share a name, at the top too

COMMENT ON TABLE cortex.namespaces IS 'the levels that hold objects, nested under another or at the top. What the engine calls one (a database, a schema, a shelf) is the engine''s word, never stored here.';
COMMENT ON COLUMN cortex.namespaces.id IS 'the model''s id (n_sales), kept when the name changes';
COMMENT ON COLUMN cortex.namespaces.name IS 'sales';
COMMENT ON COLUMN cortex.namespaces.parent IS 'the namespace it sits in; NULL at the top';
COMMENT ON COLUMN cortex.namespaces.position IS 'its place among the namespaces, in the order they were made or read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.namespaces.comment IS 'what it holds';
