-- engine_mysql.views: a view: its query as the server holds it, and how it runs; the tables and views it reads are its cortex dependencies, its columns the cortex's.
CREATE TABLE engine_mysql.views (
  id                    UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  definition            TEXT NOT NULL CHECK (length(definition) >= 1),                                                   -- its query, exactly as SHOW CREATE VIEW writes it
  algorithm             TEXT NOT NULL CHECK (algorithm IN ('UNDEFINED', 'MERGE', 'TEMPTABLE')),                           -- ALGORITHM
  definer               TEXT NOT NULL,                                                                                   -- DEFINER, as written (`app`@`%`)
  security              TEXT NOT NULL CHECK (security IN ('DEFINER', 'INVOKER')),                                         -- SQL SECURITY
  check_option          TEXT CHECK (check_option IN ('CASCADED', 'LOCAL')),                                               -- WITH ... CHECK OPTION; NULL for none
  character_set_client  TEXT NOT NULL,                                                                                   -- the client character set it was made with
  collation_connection  TEXT NOT NULL,                                                                                   -- the connection collation it was made with
  duality               BOOLEAN NOT NULL DEFAULT false,                                                                  -- true for a JSON duality view (9.7)
  flavor_options        JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
