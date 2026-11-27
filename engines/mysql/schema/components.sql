-- engine_mysql.components: a component installed on the server (INSTALL COMPONENT, 8.0 and later), by its URN.
CREATE TABLE engine_mysql.components (
  id      UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  urn     TEXT NOT NULL CHECK (urn ~ '^file://'),                                                          -- its URN, as installed (file://component_validate_password)
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
