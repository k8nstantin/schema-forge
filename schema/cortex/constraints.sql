-- cortex.constraints: a table's keys and checks, a domain's checks, and the links between tables: the ones the database enforces and the ones the design only draws. Owner: cortex.
CREATE TABLE cortex.constraints (
  id                  UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                                 -- UUIDv7, made with the row
  design              UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,                    -- the design it belongs to
  object              UUID NOT NULL,                                                                                                   -- the table or domain it is on
  name                TEXT,                                                                                                            -- its constraint name; NULL for none
  kind                TEXT NOT NULL CHECK (kind IN ('primary', 'unique', 'foreign', 'check', 'exclusion', 'not_null', 'identifier')),  -- what it is; identifier: columns that identify a row with no constraint enforcing it
  in_database         BOOLEAN NOT NULL DEFAULT true,                                                                                   -- false for a link the design draws that the database does not hold
  enforced            BOOLEAN NOT NULL DEFAULT true,                                                                                   -- false for one the database holds but does not enforce (NOT ENFORCED)
  "deferrable"        BOOLEAN NOT NULL DEFAULT false,                                                                                  -- true when it may be checked at the end of a transaction
  initially_deferred  BOOLEAN NOT NULL DEFAULT false,                                                                                  -- true when it is checked at the end unless said otherwise
  expression          TEXT,                                                                                                            -- a check's expression, in the engine's SQL
  "index"             UUID,                                                                                                            -- the index that holds a key; NULL for none
  to_object           UUID,                                                                                                            -- the table a foreign key refers to: it cannot go while this row is here; NULL when it is outside the store
  to_namespace_name   TEXT,                                                                                                            -- the namespace of a referred table outside the store, as written; NULL otherwise
  to_object_name      TEXT,                                                                                                            -- a referred table outside the store, as written; NULL otherwise
  on_delete           TEXT CHECK (on_delete IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),                       -- what happens when the row referred to is deleted; NULL for the engine's default
  on_update           TEXT CHECK (on_update IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),                       -- what happens when its key changes; NULL for the engine's default
  match_kind          TEXT CHECK (match_kind IN ('simple', 'full', 'partial')),                                                        -- how a key of several columns with some null matches; NULL for the engine's default
  position            INTEGER NOT NULL CHECK (position >= 1),                                                                          -- its place among the object's constraints
  options             JSONB NOT NULL DEFAULT '{}',                                                                                     -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  CHECK ((kind = 'check') = (expression IS NOT NULL) OR kind = 'exclusion'),
  CHECK (kind <> 'foreign' OR (to_object IS NULL) = (to_object_name IS NOT NULL)),
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "index") REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, to_object) REFERENCES cortex.objects (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX constraints_object ON cortex.constraints (design, object);
CREATE INDEX constraints_index ON cortex.constraints (design, "index");
CREATE INDEX constraints_to_object ON cortex.constraints (design, to_object);

COMMENT ON TABLE cortex.constraints IS 'a table''s keys and checks, a domain''s checks, and the links between tables: the ones the database enforces and the ones the design only draws.';
COMMENT ON COLUMN cortex.constraints.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.constraints.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.constraints.object IS 'the table or domain it is on';
COMMENT ON COLUMN cortex.constraints.name IS 'its constraint name; NULL for none';
COMMENT ON COLUMN cortex.constraints.kind IS 'what it is; identifier: columns that identify a row with no constraint enforcing it';
COMMENT ON COLUMN cortex.constraints.in_database IS 'false for a link the design draws that the database does not hold';
COMMENT ON COLUMN cortex.constraints.enforced IS 'false for one the database holds but does not enforce (NOT ENFORCED)';
COMMENT ON COLUMN cortex.constraints."deferrable" IS 'true when it may be checked at the end of a transaction';
COMMENT ON COLUMN cortex.constraints.initially_deferred IS 'true when it is checked at the end unless said otherwise';
COMMENT ON COLUMN cortex.constraints.expression IS 'a check''s expression, in the engine''s SQL';
COMMENT ON COLUMN cortex.constraints."index" IS 'the index that holds a key; NULL for none';
COMMENT ON COLUMN cortex.constraints.to_object IS 'the table a foreign key refers to: it cannot go while this row is here; NULL when it is outside the store';
COMMENT ON COLUMN cortex.constraints.to_namespace_name IS 'the namespace of a referred table outside the store, as written; NULL otherwise';
COMMENT ON COLUMN cortex.constraints.to_object_name IS 'a referred table outside the store, as written; NULL otherwise';
COMMENT ON COLUMN cortex.constraints.on_delete IS 'what happens when the row referred to is deleted; NULL for the engine''s default';
COMMENT ON COLUMN cortex.constraints.on_update IS 'what happens when its key changes; NULL for the engine''s default';
COMMENT ON COLUMN cortex.constraints.match_kind IS 'how a key of several columns with some null matches; NULL for the engine''s default';
COMMENT ON COLUMN cortex.constraints.position IS 'its place among the object''s constraints';
COMMENT ON COLUMN cortex.constraints.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
