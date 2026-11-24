-- engine_mysql.spatial_reference_systems: a spatial reference system (CREATE SPATIAL REFERENCE SYSTEM).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.spatial_reference_systems (
  id                 TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the system
  srid               INTEGER NOT NULL UNIQUE CHECK (srid >= 0),                                      -- its id
  definition         TEXT    NOT NULL CHECK (length(definition) >= 1),                               -- its definition, as well-known text
  organization       TEXT,                                                                           -- the organization that defined it; NULL when not written
  organization_srid  INTEGER,                                                                        -- its id at that organization; NULL when not written
  CHECK ((organization IS NULL) = (organization_srid IS NULL))
);

COMMENT ON TABLE engine_mysql.spatial_reference_systems IS 'a spatial reference system (CREATE SPATIAL REFERENCE SYSTEM). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.spatial_reference_systems.id IS 'the system';
COMMENT ON COLUMN engine_mysql.spatial_reference_systems.srid IS 'its id';
COMMENT ON COLUMN engine_mysql.spatial_reference_systems.definition IS 'its definition, as well-known text';
COMMENT ON COLUMN engine_mysql.spatial_reference_systems.organization IS 'the organization that defined it; NULL when not written';
COMMENT ON COLUMN engine_mysql.spatial_reference_systems.organization_srid IS 'its id at that organization; NULL when not written';
