-- cortex.required_extensions: what the database must have installed for this schema (an extension, a plugin), by name, in order. Owner: cortex.
CREATE TABLE cortex.required_extensions (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (length(id) >= 1),               -- its name, in the engine's words (postgis)
  position  NUMERIC NOT NULL UNIQUE CHECK (position > 0)                        -- its place in the schema's list of requirements; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
);

COMMENT ON TABLE cortex.required_extensions IS 'what the database must have installed for this schema (an extension, a plugin), by name, in order.';
COMMENT ON COLUMN cortex.required_extensions.id IS 'its name, in the engine''s words (postgis)';
COMMENT ON COLUMN cortex.required_extensions.position IS 'its place in the schema''s list of requirements; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
