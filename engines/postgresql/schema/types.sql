-- engine_postgresql.types: an enum, composite, domain or range type's PostgreSQL facts beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.types (
  id             UUID NOT NULL PRIMARY KEY,                                                                     -- the type
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  owner          TEXT,                                                                                          -- its owner, by role name; NULL for the one the schema is written as
  acl            JSONB,                                                                                         -- its privileges; NULL for the defaults
  range_subtype  TEXT,                                                                                          -- a range type's element type; NULL otherwise
  multirange     TEXT,                                                                                          -- a range type's multirange type name; NULL otherwise
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.types IS 'an enum, composite, domain or range type''s PostgreSQL facts beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.types.id IS 'the type';
COMMENT ON COLUMN engine_postgresql.types.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.types.owner IS 'its owner, by role name; NULL for the one the schema is written as';
COMMENT ON COLUMN engine_postgresql.types.acl IS 'its privileges; NULL for the defaults';
COMMENT ON COLUMN engine_postgresql.types.range_subtype IS 'a range type''s element type; NULL otherwise';
COMMENT ON COLUMN engine_postgresql.types.multirange IS 'a range type''s multirange type name; NULL otherwise';
