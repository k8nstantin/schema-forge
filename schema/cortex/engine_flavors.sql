-- cortex.engine_flavors: the managed services an engine runs as (Amazon RDS, Aurora, Cloud SQL, AlloyDB, Spanner), each a flavor of its engine: mostly what the engine has, less what cortex.flavor_limits says it lacks, and more what the engine's kinds and options declare for it alone. Owner: cortex.
CREATE TABLE cortex.engine_flavors (
  id        TEXT NOT NULL PRIMARY KEY,                      -- <engine>/<flavor>: mysql/rds
  engine    TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),  -- the engine it is a flavor of (mysql)
  flavor    TEXT NOT NULL CHECK (flavor ~ '^[a-z0-9_]+$'),  -- as the engine's seeds name it (rds, aurora, cloudsql, alloydb, spanner)
  name      TEXT NOT NULL CHECK (length(name) >= 1),        -- as people say it (Amazon RDS for MySQL)
  position  NUMERIC NOT NULL CHECK (position > 0),          -- its place among its engine's flavors, for listing
  about     TEXT NOT NULL CHECK (length(about) >= 1),       -- what it is, and how its versions follow the engine's
  UNIQUE (engine, flavor),
  UNIQUE (engine, position),
  CHECK (id = engine || '/' || flavor)
);

COMMENT ON TABLE cortex.engine_flavors IS 'the managed services an engine runs as (Amazon RDS, Aurora, Cloud SQL, AlloyDB, Spanner), each a flavor of its engine: mostly what the engine has, less what cortex.flavor_limits says it lacks, and more what the engine''s kinds and options declare for it alone.';
COMMENT ON COLUMN cortex.engine_flavors.id IS '<engine>/<flavor>: mysql/rds';
COMMENT ON COLUMN cortex.engine_flavors.engine IS 'the engine it is a flavor of (mysql)';
COMMENT ON COLUMN cortex.engine_flavors.flavor IS 'as the engine''s seeds name it (rds, aurora, cloudsql, alloydb, spanner)';
COMMENT ON COLUMN cortex.engine_flavors.name IS 'as people say it (Amazon RDS for MySQL)';
COMMENT ON COLUMN cortex.engine_flavors.position IS 'its place among its engine''s flavors, for listing';
COMMENT ON COLUMN cortex.engine_flavors.about IS 'what it is, and how its versions follow the engine''s';
