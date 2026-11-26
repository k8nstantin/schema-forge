-- engine_postgresql.columns: what PostgreSQL says of a column beyond the cortex; a row only where it says something. Owner: postgresql.
CREATE TABLE engine_postgresql.columns (
  id             BIGINT NOT NULL PRIMARY KEY,                                                                   -- the column
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  is_local       BOOLEAN NOT NULL DEFAULT true,                                                                 -- false when it comes from a parent table only
  inherit_count  INTEGER NOT NULL DEFAULT 0 CHECK (inherit_count >= 0),                                         -- how many parents it comes from
  options        JSONB,                                                                                         -- its options as the server writes them; NULL for none
  acl            JSONB,                                                                                         -- its column privileges; NULL for none
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.columns IS 'what PostgreSQL says of a column beyond the cortex; a row only where it says something.';
COMMENT ON COLUMN engine_postgresql.columns.id IS 'the column';
COMMENT ON COLUMN engine_postgresql.columns.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.columns.is_local IS 'false when it comes from a parent table only';
COMMENT ON COLUMN engine_postgresql.columns.inherit_count IS 'how many parents it comes from';
COMMENT ON COLUMN engine_postgresql.columns.options IS 'its options as the server writes them; NULL for none';
COMMENT ON COLUMN engine_postgresql.columns.acl IS 'its column privileges; NULL for none';
