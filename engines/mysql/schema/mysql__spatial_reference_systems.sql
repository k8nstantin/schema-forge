-- mysql__spatial_reference_systems: a spatial reference system (CREATE SPATIAL REFERENCE SYSTEM).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__spatial_reference_systems (
  id                 TEXT     NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the system
  srid               INTEGER  NOT NULL UNIQUE CHECK (srid >= 0),          -- its id
  definition         TEXT     NOT NULL CHECK (length(definition) >= 1),   -- its definition, as well-known text
  organization       TEXT,                                                -- the organization that defined it; NULL when not written
  organization_srid  INTEGER,                                             -- its id at that organization; NULL when not written
  CHECK ((organization IS NULL) = (organization_srid IS NULL))
) STRICT;
