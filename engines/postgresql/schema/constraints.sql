-- engine_postgresql.constraints: what PostgreSQL says of a constraint beyond the cortex; a row only where it says something. Owner: postgresql.
CREATE TABLE engine_postgresql.constraints (
  id             BIGINT NOT NULL PRIMARY KEY,                                                                   -- the constraint
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  validated      BOOLEAN NOT NULL DEFAULT true,                                                                 -- false when made NOT VALID: existing rows are not checked
  no_inherit     BOOLEAN NOT NULL DEFAULT false,                                                                -- true when it does not pass to child tables
  is_local       BOOLEAN NOT NULL DEFAULT true,                                                                 -- false when it comes from a parent table only
  inherit_count  INTEGER NOT NULL DEFAULT 0 CHECK (inherit_count >= 0),                                         -- how many parents it comes from
  operators      JSONB,                                                                                         -- an exclusion's operators, one per part (["=", "&&"]); NULL otherwise
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.constraints (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.constraints IS 'what PostgreSQL says of a constraint beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_postgresql.constraints.id IS 'the constraint';
COMMENT ON COLUMN engine_postgresql.constraints.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.constraints.validated IS 'false when made NOT VALID: existing rows are not checked';
COMMENT ON COLUMN engine_postgresql.constraints.no_inherit IS 'true when it does not pass to child tables';
COMMENT ON COLUMN engine_postgresql.constraints.is_local IS 'false when it comes from a parent table only';
COMMENT ON COLUMN engine_postgresql.constraints.inherit_count IS 'how many parents it comes from';
COMMENT ON COLUMN engine_postgresql.constraints.operators IS 'an exclusion''s operators, one per part (["=", "&&"]); NULL otherwise';
