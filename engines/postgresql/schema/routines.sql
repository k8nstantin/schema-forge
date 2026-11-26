-- engine_postgresql.routines: what PostgreSQL says of a function or procedure beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.routines (
  id           BIGINT NOT NULL PRIMARY KEY,                                                                   -- the routine
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  volatility   TEXT NOT NULL DEFAULT 'volatile' CHECK (volatility IN ('immutable', 'stable', 'volatile')),    -- what it promises about its results
  parallel     TEXT NOT NULL DEFAULT 'unsafe' CHECK (parallel IN ('safe', 'restricted', 'unsafe')),           -- whether it may run in a parallel query
  strict       BOOLEAN NOT NULL DEFAULT false,                                                                -- true when it returns null on any null argument
  leakproof    BOOLEAN NOT NULL DEFAULT false,                                                                -- true when it reveals nothing of its arguments
  returns_set  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when it returns rows
  cost         NUMERIC,                                                                                       -- its estimated cost; NULL for the default
  result_rows  NUMERIC,                                                                                       -- its estimated rows; NULL for the default
  config       JSONB,                                                                                         -- settings it runs with (["search_path=features"]); NULL for none
  owner        TEXT,                                                                                          -- its owner, by role name; NULL for the one the schema is written as
  acl          JSONB,                                                                                         -- its privileges; NULL for the defaults
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.routines (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.routines IS 'what PostgreSQL says of a function or procedure beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.routines.id IS 'the routine';
COMMENT ON COLUMN engine_postgresql.routines.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.routines.volatility IS 'what it promises about its results';
COMMENT ON COLUMN engine_postgresql.routines.parallel IS 'whether it may run in a parallel query';
COMMENT ON COLUMN engine_postgresql.routines.strict IS 'true when it returns null on any null argument';
COMMENT ON COLUMN engine_postgresql.routines.leakproof IS 'true when it reveals nothing of its arguments';
COMMENT ON COLUMN engine_postgresql.routines.returns_set IS 'true when it returns rows';
COMMENT ON COLUMN engine_postgresql.routines.cost IS 'its estimated cost; NULL for the default';
COMMENT ON COLUMN engine_postgresql.routines.result_rows IS 'its estimated rows; NULL for the default';
COMMENT ON COLUMN engine_postgresql.routines.config IS 'settings it runs with (["search_path=features"]); NULL for none';
COMMENT ON COLUMN engine_postgresql.routines.owner IS 'its owner, by role name; NULL for the one the schema is written as';
COMMENT ON COLUMN engine_postgresql.routines.acl IS 'its privileges; NULL for the defaults';
