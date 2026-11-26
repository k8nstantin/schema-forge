-- cortex.workspace_parameters: every value a person may want changed without a new build: the product's name, labels, limits and defaults. Owner: cortex.
CREATE TABLE cortex.workspace_parameters (
  id          TEXT NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),  -- the key, dotted by what it belongs to: product.name
  value       JSONB NOT NULL,                                                                  -- its value: a string, a number, true or false, a list or an object
  about       TEXT NOT NULL CHECK (length(about) >= 1),                                        -- what it is and where it shows, for the person who changes it
  changed_at  TIMESTAMPTZ,                                                                     -- when a person last changed it; NULL while it holds the value its seed gave
  changed_by  TEXT,                                                                            -- who changed it; NULL while it holds the value its seed gave
  CHECK ((changed_at IS NULL) = (changed_by IS NULL))
);

COMMENT ON TABLE cortex.workspace_parameters IS 'every value a person may want changed without a new build: the product''s name, labels, limits and defaults.';
COMMENT ON COLUMN cortex.workspace_parameters.id IS 'the key, dotted by what it belongs to: product.name';
COMMENT ON COLUMN cortex.workspace_parameters.value IS 'its value: a string, a number, true or false, a list or an object';
COMMENT ON COLUMN cortex.workspace_parameters.about IS 'what it is and where it shows, for the person who changes it';
COMMENT ON COLUMN cortex.workspace_parameters.changed_at IS 'when a person last changed it; NULL while it holds the value its seed gave';
COMMENT ON COLUMN cortex.workspace_parameters.changed_by IS 'who changed it; NULL while it holds the value its seed gave';
