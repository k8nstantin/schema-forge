-- cortex.routine_parameters: the parameters of a routine, in order, as the server reads them: for search and the canvas. Owner: cortex.
CREATE TABLE cortex.routine_parameters (
  id             UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  routine        UUID NOT NULL,                                                                                 -- the routine
  position       INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  name           TEXT,                                                                                          -- its name; NULL for an unnamed one
  type           TEXT NOT NULL CHECK (length(type) >= 1),                                                       -- its type, as the engine writes it
  mode           TEXT NOT NULL DEFAULT 'in' CHECK (mode IN ('in', 'out', 'in_out', 'variadic', 'table')),       -- how it is passed; table: a column of what a function returns
  default_value  TEXT,                                                                                          -- its default, in the engine's SQL; NULL for none
  options        JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (routine, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, routine) REFERENCES cortex.routines (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX routine_parameters_routine ON cortex.routine_parameters (design, routine);

COMMENT ON TABLE cortex.routine_parameters IS 'the parameters of a routine, in order, as the server reads them: for search and the canvas.';
COMMENT ON COLUMN cortex.routine_parameters.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.routine_parameters.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.routine_parameters.routine IS 'the routine';
COMMENT ON COLUMN cortex.routine_parameters.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.routine_parameters.name IS 'its name; NULL for an unnamed one';
COMMENT ON COLUMN cortex.routine_parameters.type IS 'its type, as the engine writes it';
COMMENT ON COLUMN cortex.routine_parameters.mode IS 'how it is passed; table: a column of what a function returns';
COMMENT ON COLUMN cortex.routine_parameters.default_value IS 'its default, in the engine''s SQL; NULL for none';
COMMENT ON COLUMN cortex.routine_parameters.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
