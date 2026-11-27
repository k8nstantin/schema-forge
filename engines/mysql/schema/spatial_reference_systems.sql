-- engine_mysql.spatial_reference_systems: a spatial reference system made on the server (CREATE SPATIAL REFERENCE SYSTEM, 8.0 and later), not one MySQL ships.
CREATE TABLE engine_mysql.spatial_reference_systems (
  id                        UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object; its name is the cortex object's
  design                    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  srs_id                    BIGINT NOT NULL CHECK (srs_id >= 0),                                                             -- its SRID
  definition                TEXT NOT NULL CHECK (length(definition) >= 1),                                                   -- DEFINITION, its WKT
  organization              TEXT,                                                                                            -- ORGANIZATION, where written
  organization_coordsys_id  BIGINT,                                                                                          -- the organization's IDENTIFIED BY, where written
  description               TEXT,                                                                                            -- DESCRIPTION, where written
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
