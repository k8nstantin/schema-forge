-- cortex.option_declarations: every option an engine adds to a part of the model, as the engine declares it: its type, the values it may take, and the versions that have it; a new option, or a new engine, is new rows, never a new column (decision declared-options). Owner: cortex.
CREATE TABLE cortex.option_declarations (
  id          TEXT NOT NULL PRIMARY KEY,                                                                                                                                                                                                                                                            -- <engine>/<part>/<name>: mysql/objects/row_format
  engine      TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),                                                                                                                                                                                                                                        -- the engine (mysql)
  part        TEXT NOT NULL CHECK (part IN ('namespaces', 'objects', 'columns', 'column_identities', 'constraints', 'constraint_columns', 'dependencies', 'domains', 'enum_values', 'indexes', 'index_parts', 'partitionings', 'partitions', 'routines', 'routine_parameters', 'sequences', 'triggers', 'views')),  -- the part of the model it is an option of, as its table is named (objects)
  name        TEXT NOT NULL CHECK (name ~ '^[a-z0-9_]+$'),                                                                                                                                                                                                                                          -- its key in the part's options (row_format)
  value_type  TEXT NOT NULL CHECK (value_type IN ('string', 'number', 'boolean', 'json')),                                                                                                                                                                                                          -- what its value is, as JSON names it: string, number, boolean, or json for a list or an object
  nullable    BOOLEAN NOT NULL DEFAULT true,                                                                                                                                                                                                                                                        -- false when the option, once written, may not be null
  choices     JSONB,                                                                                                                                                                                                                                                                                -- the only values it may take, as a list (["UNDEFINED", "MERGE", "TEMPTABLE"]); NULL for any of its type
  since       TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                                                                                                                                                                                                            -- the first version that has it; NULL for every version from the oldest
  "until"     TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                                                                                                                                                                                                            -- the last version that has it; NULL for every version to the newest
  about       TEXT NOT NULL CHECK (length(about) >= 1),                                                                                                                                                                                                                                             -- what it is, in words the canvas shows beside it
  flavor      TEXT,                                                                                                                                                                                                                                                                                 -- the one flavor that has it (postgresql/spanner's ttl_interval); NULL for every flavor of the engine
  UNIQUE (engine, part, name),
  FOREIGN KEY (flavor) REFERENCES cortex.engine_flavors (id) DEFERRABLE INITIALLY DEFERRED,
  CHECK (flavor LIKE engine || '/%'),
  CHECK (id = engine || '/' || part || '/' || name),
  CHECK (choices IS NULL OR jsonb_typeof(choices) = 'array')
);

COMMENT ON TABLE cortex.option_declarations IS 'every option an engine adds to a part of the model, as the engine declares it: its type, the values it may take, and the versions that have it; a new option, or a new engine, is new rows, never a new column (decision declared-options).';
COMMENT ON COLUMN cortex.option_declarations.id IS '<engine>/<part>/<name>: mysql/objects/row_format';
COMMENT ON COLUMN cortex.option_declarations.engine IS 'the engine (mysql)';
COMMENT ON COLUMN cortex.option_declarations.part IS 'the part of the model it is an option of, as its table is named (objects)';
COMMENT ON COLUMN cortex.option_declarations.name IS 'its key in the part''s options (row_format)';
COMMENT ON COLUMN cortex.option_declarations.value_type IS 'what its value is, as JSON names it: string, number, boolean, or json for a list or an object';
COMMENT ON COLUMN cortex.option_declarations.nullable IS 'false when the option, once written, may not be null';
COMMENT ON COLUMN cortex.option_declarations.choices IS 'the only values it may take, as a list (["UNDEFINED", "MERGE", "TEMPTABLE"]); NULL for any of its type';
COMMENT ON COLUMN cortex.option_declarations.since IS 'the first version that has it; NULL for every version from the oldest';
COMMENT ON COLUMN cortex.option_declarations."until" IS 'the last version that has it; NULL for every version to the newest';
COMMENT ON COLUMN cortex.option_declarations.about IS 'what it is, in words the canvas shows beside it';
COMMENT ON COLUMN cortex.option_declarations.flavor IS 'the one flavor that has it (postgresql/spanner''s ttl_interval); NULL for every flavor of the engine';
