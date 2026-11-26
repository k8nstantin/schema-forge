-- cortex.reference_kinds: the kinds of object a reference of the model may point at, as each engine declares them: a grant's grantee is a role or an account, a trigger's parent a table, what a foreign table uses as its server a foreign server. A foreign key holds that the row pointed at exists; the guard check_references holds that it is of a kind declared here. Owner: cortex.
CREATE TABLE cortex.reference_kinds (
  id               TEXT NOT NULL PRIMARY KEY,                                                               -- <engine>/<part>.<field>[/<condition>]: postgresql/cortex.dependencies.uses/as=server
  engine           TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),                                           -- the engine
  part             TEXT NOT NULL CHECK (part ~ '^(cortex|engine_[a-z0-9_]+)\.[a-z_]+$'),                    -- the table the reference is a column of (cortex.privileges)
  field            TEXT NOT NULL CHECK (field ~ '^[a-z_]+$'),                                               -- the column that refers to an object (grantee)
  condition_field  TEXT CHECK (condition_field ~ '^[a-z_]+$'),                                              -- a column of the same row, or a key of its options, the rule applies by (as, kind, what); NULL for every row
  condition_value  TEXT,                                                                                    -- the value it applies at (server); empty for the rows with none; NULL with no condition
  kinds            JSONB NOT NULL CHECK (jsonb_typeof(kinds) = 'array' AND jsonb_array_length(kinds) >= 1), -- the kinds the object referred to may be of (["role"])
  about            TEXT NOT NULL CHECK (length(about) >= 1),                                                -- what the reference is, in a sentence
  UNIQUE NULLS NOT DISTINCT (engine, part, field, condition_field, condition_value),
  CHECK ((condition_field IS NULL) = (condition_value IS NULL))
);

COMMENT ON TABLE cortex.reference_kinds IS 'the kinds of object a reference of the model may point at, as each engine declares them: a grant''s grantee is a role or an account, a trigger''s parent a table, what a foreign table uses as its server a foreign server. A foreign key holds that the row pointed at exists; the guard check_references holds that it is of a kind declared here.';
COMMENT ON COLUMN cortex.reference_kinds.id IS '<engine>/<part>.<field>[/<condition>]: postgresql/cortex.dependencies.uses/as=server';
COMMENT ON COLUMN cortex.reference_kinds.engine IS 'the engine';
COMMENT ON COLUMN cortex.reference_kinds.part IS 'the table the reference is a column of (cortex.privileges)';
COMMENT ON COLUMN cortex.reference_kinds.field IS 'the column that refers to an object (grantee)';
COMMENT ON COLUMN cortex.reference_kinds.condition_field IS 'a column of the same row, or a key of its options, the rule applies by (as, kind, what); NULL for every row';
COMMENT ON COLUMN cortex.reference_kinds.condition_value IS 'the value it applies at (server); empty for the rows with none; NULL with no condition';
COMMENT ON COLUMN cortex.reference_kinds.kinds IS 'the kinds the object referred to may be of (["role"])';
COMMENT ON COLUMN cortex.reference_kinds.about IS 'what the reference is, in a sentence';
