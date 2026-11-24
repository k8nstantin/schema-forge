-- workspace.parameters: every value a person may want changed without a new build: the product's name, labels, limits and defaults. Owner: workspace.
-- Nothing a person may want changed is written in code (decision parameters-not-code); code reads it here. A version ships its
-- parameters as seeds (schema/workspace/seeds/), inserted only where the key is missing, so a value someone changed is kept.
CREATE TABLE workspace.parameters (
  id          TEXT        NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),  -- the key, dotted by what it belongs to: product.name
  value       JSONB       NOT NULL,                                                                   -- its value: a string, a number, true or false, a list or an object
  about       TEXT        NOT NULL CHECK (length(about) >= 1),                                        -- what it is and where it shows, for the person who changes it
  changed_at  TIMESTAMPTZ,                                                                            -- when a person last changed it; NULL while it holds the value its seed gave
  changed_by  TEXT,                                                                                   -- who changed it; NULL while it holds the value its seed gave
  CHECK ((changed_at IS NULL) = (changed_by IS NULL))
);

COMMENT ON TABLE workspace.parameters IS 'every value a person may want changed without a new build: the product''s name, labels, limits and defaults. Nothing a person may want changed is written in code (decision parameters-not-code); code reads it here. A version ships its parameters as seeds (schema/workspace/seeds/), inserted only where the key is missing, so a value someone changed is kept.';
COMMENT ON COLUMN workspace.parameters.id IS 'the key, dotted by what it belongs to: product.name';
COMMENT ON COLUMN workspace.parameters.value IS 'its value: a string, a number, true or false, a list or an object';
COMMENT ON COLUMN workspace.parameters.about IS 'what it is and where it shows, for the person who changes it';
COMMENT ON COLUMN workspace.parameters.changed_at IS 'when a person last changed it; NULL while it holds the value its seed gave';
COMMENT ON COLUMN workspace.parameters.changed_by IS 'who changed it; NULL while it holds the value its seed gave';
